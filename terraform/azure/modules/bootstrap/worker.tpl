#cloud-config
package_update: true
package_upgrade: false

packages:
  - curl
  - python3
  - apt-transport-https
  - ca-certificates
  - gnupg

runcmd:
  - swapoff -a
  - sed -i '/ swap / s/^/#/' /etc/fstab
  - systemctl mask swap.target
  - modprobe overlay
  - modprobe br_netfilter
  - |
    cat <<EOF > /etc/modules-load.d/k8s.conf
    overlay
    br_netfilter
    EOF
  - |
    cat <<EOF > /etc/sysctl.d/k8s.conf
    net.bridge.bridge-nf-call-iptables=1
    net.bridge.bridge-nf-call-ip6tables=1
    net.ipv4.ip_forward=1
    EOF
  - sysctl --system
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  - chmod a+r /etc/apt/keyrings/docker.asc
  - |
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
    https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null
  - apt-get update -y
  - apt-get install -y containerd.io iptables
  - mkdir -p /etc/containerd
  - containerd config default > /etc/containerd/config.toml
  - sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  - systemctl daemon-reload
  - systemctl enable containerd
  - systemctl restart containerd
  - update-alternatives --set iptables /usr/sbin/iptables-legacy
  - update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  - chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  - |
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" | \
    tee /etc/apt/sources.list.d/kubernetes.list
  - apt-get update -y
  - apt-get install -y kubelet=1.30.4-1.1 kubeadm=1.30.4-1.1 kubectl=1.30.4-1.1
  - apt-mark hold kubelet kubeadm kubectl
  - |
    printf 'KUBELET_EXTRA_ARGS=\n' > /etc/default/kubelet
  - |
    printf '[Service]\nEnvironment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"\nEnvironment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"\nEnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env\nEnvironmentFile=-/etc/default/kubelet\nExecStart=\nExecStart=/usr/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS\n' > /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf
  - systemctl daemon-reload
  - systemctl enable kubelet
  - mkdir -p /etc/kubernetes/pki /etc/kubernetes/ssl
  - ln -sf /etc/kubernetes/pki/ca.crt /etc/kubernetes/ssl/ca.crt
  # k8s-iptables service — đảm bảo CoreDNS reach API server
  - |
    tee /usr/local/bin/k8s-iptables.sh << 'IPTABLES'
    #!/bin/bash
    set -uo pipefail
    MASTER_IP=""
    for i in $(seq 1 30); do
      MASTER_IP=$(getent hosts master.k8s.internal | awk '{print $1}')
      [ -n "$MASTER_IP" ] && break
      echo "Waiting for DNS master.k8s.internal..."
      sleep 10
    done
    [ -z "$MASTER_IP" ] && exit 1
    for i in $(seq 1 60); do
      if iptables -t nat -L KUBE-SERVICES 2>/dev/null | grep -q "10.233.0.1"; then
        iptables -t nat -D OUTPUT -d 10.233.0.1/32 -p tcp --dport 443 \
          -j DNAT --to-destination $MASTER_IP:6443 2>/dev/null || true
        exit 0
      fi
      iptables -t nat -C OUTPUT -d 10.233.0.1/32 -p tcp --dport 443 \
        -j DNAT --to-destination $MASTER_IP:6443 2>/dev/null || \
      iptables -t nat -A OUTPUT -d 10.233.0.1/32 -p tcp --dport 443 \
        -j DNAT --to-destination $MASTER_IP:6443 2>/dev/null || true
      iptables -t nat -C POSTROUTING -d $MASTER_IP -p tcp --dport 6443 \
        -j MASQUERADE 2>/dev/null || \
      iptables -t nat -A POSTROUTING -d $MASTER_IP -p tcp --dport 6443 \
        -j MASQUERADE 2>/dev/null || true
      sleep 10
    done
    exit 0
    IPTABLES
  - chmod +x /usr/local/bin/k8s-iptables.sh
  - |
    tee /etc/systemd/system/k8s-iptables.service << 'SERVICE'
    [Unit]
    Description=K8s iptables rules for CoreDNS and Calico
    After=network-online.target
    Before=kubelet.service
    Wants=network-online.target

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/usr/local/bin/k8s-iptables.sh
    StandardOutput=journal
    StandardError=journal

    [Install]
    WantedBy=multi-user.target
    SERVICE
  - systemctl daemon-reload
  - systemctl enable k8s-iptables.service
  - |
    cat <<'SCRIPT' > /usr/local/bin/k8s-join.sh
    #!/bin/bash

    MASTER_HOST="${master_dns}"
    MAX_RETRY=60

    until systemctl is-active --quiet containerd; do
      echo "Waiting for containerd..."
      sleep 5
    done
    echo "containerd ready."

    until command -v kubeadm &>/dev/null; do
      echo "kubeadm not found yet, waiting 10s..."
      sleep 10
    done
    echo "kubeadm found: $(which kubeadm)"

    for i in $(seq 1 $MAX_RETRY); do
      MASTER_IP=$(getent hosts $MASTER_HOST | awk '{print $1}')
      if [ -z "$MASTER_IP" ]; then
        echo "DNS not resolved yet, attempt $i/$MAX_RETRY — waiting 15s..."
        sleep 15
        continue
      fi
      echo "Master resolved: $MASTER_HOST -> $MASTER_IP"

      TOKEN=$(curl -sf --max-time 5 http://$MASTER_IP:9999 2>/dev/null | tr -d '[:space:]')
      CAHASH=$(curl -sf --max-time 5 http://$MASTER_IP:9998 2>/dev/null | tr -d '[:space:]')

      if [ -n "$TOKEN" ] && [ -n "$CAHASH" ]; then
        echo "Got token and cahash, joining cluster..."

        if [ -f /etc/kubernetes/kubelet.conf ]; then
          echo "Resetting existing state..."
          systemctl stop kubelet 2>/dev/null || true
          kubeadm reset -f --cleanup-tmp-dir
          rm -rf /etc/kubernetes /var/lib/kubelet /etc/cni/net.d
          iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
          printf '[Service]\nEnvironment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"\nEnvironment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"\nEnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env\nEnvironmentFile=-/etc/default/kubelet\nExecStart=\nExecStart=/usr/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS\n' > /usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf
          systemctl daemon-reload
        fi

        rm -f /etc/kubernetes/pki/ca.crt
        mkdir -p /etc/kubernetes/pki /etc/kubernetes/ssl
        ln -sf /etc/kubernetes/pki/ca.crt /etc/kubernetes/ssl/ca.crt

        kubeadm join $MASTER_IP:6443 \
          --token "$TOKEN" \
          --discovery-token-ca-cert-hash "sha256:$CAHASH"

        if [ $? -eq 0 ]; then
          echo "Successfully joined cluster!"

          # Static route cho service CIDR
          ip route add 10.233.0.0/18 via $MASTER_IP dev eth0 2>/dev/null || true

          # Start k8s-iptables service
          systemctl start k8s-iptables.service || true

          # Set ProviderID từ Azure IMDS
          VM_ID=$(curl -sf --max-time 10 \
            -H "Metadata: true" \
            "http://169.254.169.254/metadata/instance/compute/resourceId?api-version=2021-02-01&format=text" \
            2>/dev/null || echo "")

          if [ -n "$VM_ID" ]; then
            printf "KUBELET_EXTRA_ARGS=--provider-id=azure://$VM_ID\n" > /etc/default/kubelet
            echo "ProviderID set: azure://$VM_ID"
          fi

          systemctl daemon-reload
          systemctl restart kubelet

          echo "Worker setup complete!"
          exit 0
        else
          echo "Join failed, resetting..."
          systemctl stop kubelet 2>/dev/null || true
          kubeadm reset -f --cleanup-tmp-dir
          rm -rf /etc/kubernetes /var/lib/kubelet /etc/cni/net.d
          iptables -F && iptables -t nat -F && iptables -t mangle -F && iptables -X
        fi
      else
        echo "Token empty, attempt $i/$MAX_RETRY — waiting 30s..."
      fi

      sleep 30
    done

    echo "Failed to join after $MAX_RETRY attempts"
    exit 1
    SCRIPT
  - chmod +x /usr/local/bin/k8s-join.sh
  - |
    cat <<'SERVICE' > /etc/systemd/system/k8s-join.service
    [Unit]
    Description=Join Kubernetes Cluster
    After=network-online.target containerd.service k8s-iptables.service
    Wants=network-online.target
    ConditionPathExists=!/etc/kubernetes/kubelet.conf

    [Service]
    Type=oneshot
    ExecStart=/usr/local/bin/k8s-join.sh
    RemainAfterExit=yes
    Restart=on-failure
    RestartSec=30

    [Install]
    WantedBy=multi-user.target
    SERVICE
  - systemctl daemon-reload
  - systemctl enable k8s-join.service
  - systemctl start k8s-join.service

final_message: "Worker bootstrap OK"