#!/usr/bin/env bash
# Usage: ./worker_install_k0.sh <controller_ip>
set -euo pipefail
CTL_IP=${1:? "controller IP required"}
USER_HOME="${HOME:-}"
if [ -z "$USER_HOME" ]; then
  USER_HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"
fi
[ -n "$USER_HOME" ] || USER_HOME="/tmp"
LOG_FILE="${USER_HOME}/k0s_worker.log"
if [ ! -f "/tmp/common_k0.sh" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "${SCRIPT_DIR}/common_k0.sh" ] && cp "${SCRIPT_DIR}/common_k0.sh" /tmp/common_k0.sh
fi
source /tmp/common_k0.sh

install_deps
install_k0s

# --- Node IP setup (nested VMs only) ---
# Nested VMs have hostnames like ins0vm, ins1vm, etc.
# Derive the instance index and add the routable /32 address to the NIC so
# kubelet registers with 10.1.<id>.7 rather than the libvirt-internal IP.
IFACE="enp1s0"
KUBELET_ARGS="--max-pods=243 --node-status-update-frequency=1s"
LABEL_ARGS=()

if [[ "$HOSTNAME" =~ ^ins([0-9]+)vm$ ]]; then
  INSTANCE_ID="${BASH_REMATCH[1]}"
  NODE_IP="10.1.${INSTANCE_ID}.7"
  sudo ip addr add "${NODE_IP}/32" dev "$IFACE" 2>/dev/null || true
  KUBELET_ARGS="${KUBELET_ARGS} --node-ip=${NODE_IP}"
  LABEL_ARGS=(--labels "dilated=true")
fi

# --- Fetch worker token from controller ---
if ! command -v sshpass >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo apt-get install -y sshpass
fi

remote="ubuntu@${CTL_IP}:~/token-file"
target="${USER_HOME}/token-file"
delay=5
max_attempts=10000
attempt=1
password="1997"

while (( attempt <= max_attempts )); do
  [[ -f $target ]] && { echo "✓ $target is present; done."; break; }
  echo "Attempt $attempt: Attempting to copy token-file..."
  if sshpass -p "$password" scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null "$remote" "$target"; then
    echo "✓ Copy succeeded."
    break
  else
    (( attempt == max_attempts )) && { echo "❌ Reached max attempts ($max_attempts). Exiting."; exit 1; }
    echo "⚠️  token-file not found on controller or copy failed; retrying in ${delay}s …"
    sleep "$delay"
    ((attempt++))
  fi
done

# --- Install and start worker ---
log "Joining cluster with token"
sudo k0s install worker \
  --token-file "${USER_HOME}/token-file" \
  --kubelet-extra-args="${KUBELET_ARGS}" \
  "${LABEL_ARGS[@]}"
sudo systemctl enable --now k0sworker
