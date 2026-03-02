#!/usr/bin/env bash
set -euo pipefail
LOG_FILE="/home/ubuntu/k0s_master.log"
if [ ! -f "/tmp/common_k0.sh" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "${SCRIPT_DIR}/common_k0.sh" ] && cp "${SCRIPT_DIR}/common_k0.sh" /tmp/common_k0.sh
fi
source /tmp/common_k0.sh

install_deps
install_k0s

# Install yq for YAML manipulation (needed before k0s config is modified)
sudo wget -qO /usr/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/bin/yq

# Add controller /32 address to inner VM NIC and register kubelet on the
# libvirt-internal controller IP.
IFACE="enp1s0"
NODE_IP="10.2.0.7"
sudo ip addr add "${NODE_IP}/32" dev "$IFACE" 2>/dev/null || true

# Update the hostname (used as node name in k8s)
until sudo hostnamectl set-hostname "controller"; do
  echo "Failed to set hostname..."
  sleep 5
done

log "Generating k0s config"
k0s config create > k0s.yaml

# Use custom CNI provider — Cilium will be installed separately via Helm
sed -i 's/^    provider: kuberouter$/    provider: custom/' k0s.yaml

# Extend node-monitor-grace-period for the dilated-clock environment
sed -i 's/^  controllerManager: {}/  controllerManager:\n    extraArgs:\n      node-monitor-grace-period: 50000s/g' k0s.yaml

# Set API externalAddress so kubeconfig and worker join tokens point to the
# controller's inner network address.
yq e ".spec.api.externalAddress = \"${NODE_IP}\"" -i k0s.yaml

log "Installing controller service"
sudo k0s install controller -c k0s.yaml --enable-worker \
  --kubelet-extra-args="--max-pods=243 --node-ip=${NODE_IP}"

log "Starting k0s"
sudo k0s start

# Generate and save worker token (loop until k0s API is ready)
dest=/home/ubuntu/token-file
delay=5
while :; do
  echo "⇒ Requesting worker token …"
  token=$(sudo k0s token create --role=worker --expiry=100h || true)
  if [[ -n $token ]]; then
    printf '%s\n' "$token" > "$dest"
    echo "✓ Token saved to $dest"
    break
  else
    echo "⚠️  k0s returned an empty token; retrying in ${delay}s …"
    sleep "$delay"
  fi
done

# Generate kubeconfig — use k0s kubeconfig admin so the server address
# reflects externalAddress (${NODE_IP}:6443).
sudo k0s kubeconfig admin > /home/ubuntu/admin.conf
chown ubuntu:ubuntu /home/ubuntu/admin.conf
chmod 600 /home/ubuntu/admin.conf
grep -qF 'KUBECONFIG' /home/ubuntu/.bashrc || \
  echo 'export KUBECONFIG=/home/ubuntu/admin.conf' >> /home/ubuntu/.bashrc

# Wait for the controller node to register before removing the taint
until sudo k0s kubectl get node controller >/dev/null 2>&1; do
  echo "Waiting for controller node to register..."
  sleep 5
done
sudo k0s kubectl taint nodes controller node-role.kubernetes.io/control-plane- || true

log "Worker join-token written to /home/ubuntu/token-file"

# Install Cilium CNI via Helm
# Geneve tunnel is used because nodes span different Azure subnets (10.1.x, 10.3.x, 10.4.x)
# and Azure VNet has no UDRs for pod CIDRs — native routing would require them.
export KUBECONFIG=/home/ubuntu/admin.conf

log "Adding Cilium Helm repo"
helm repo add cilium https://helm.cilium.io/ >>"$LOG_FILE"
helm repo update >>"$LOG_FILE"

log "Installing Cilium (Geneve tunnel, SCTP enabled, kube-proxy kept)"
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system --create-namespace \
  --set kubeProxyReplacement=false \
  --set sctp.enabled=true \
  --set ipam.mode=kubernetes \
  --set routingMode=tunnel \
  --set tunnelProtocol=geneve \
  --set genevePort=6081 \
  --set k8sServiceHost="${NODE_IP}" \
  --set k8sServicePort=6443 \
  >>"$LOG_FILE"

log "Waiting for Cilium pods to be ready"
until sudo k0s kubectl -n kube-system get daemonset/cilium >/dev/null 2>&1; do
  echo "Waiting for Cilium daemonset to be created..."
  sleep 5
done
sudo k0s kubectl -n kube-system rollout status daemonset/cilium --timeout=300s || true

log "Cilium install complete"
