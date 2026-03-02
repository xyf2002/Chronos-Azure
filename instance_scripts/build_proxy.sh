#!/bin/bash

# Define Azure user home directory
AZURE_USER_HOME="/home/azureuser"

exec >> $AZURE_USER_HOME/build.log
exec 2>&1
# Color output
GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'
if ! test -t 1; then
    GREEN=""
    BLUE=""
    NC=""
fi

function step_log() {
    echo ""
    echo "====================[ $1 ]===================="
    date
    if [ -n "$2" ]; then
        echo ""
        echo "$2"
    fi
    echo ""
}
NUM_MACHINE="$1"
PROXY_ID="${2:-0}"          # proxy index (0, 1, 2, ...), default 0
PROXY_NODE_ID="$PROXY_ID"

PROXY_GATEWAY="10.3.$((PROXY_ID+1)).1"

echo "Proxy ID: ${PROXY_ID}, Gateway: ${PROXY_GATEWAY}"

kernel_repo="andrewferguson/phobos-proxy"
  sudo apt update
  sudo apt-get install -yqq build-essential libsctp-dev lksctp-tools zlib1g-dev
  sudo modprobe sctp
git clone --quiet "https://github.com/${kernel_repo}.git" $AZURE_USER_HOME/phobos-proxy
cd $AZURE_USER_HOME/phobos-proxy

# Add routes to all instance networks via this proxy's gateway
for (( i=0; i<NUM_MACHINE; i++ )); do
  # Route to first NIC subnet (10.1.i.0/24)
  echo "Adding route: 10.1.${i}.0/24 via ${PROXY_GATEWAY}"
  sudo ip route add 10.1."${i}".0/24 via ${PROXY_GATEWAY} dev eth0 || echo "Route to 10.1.${i}.0/24 may already exist"

  # Route to second NIC subnet (10.5.i.0/24)
  echo "Adding route: 10.5.${i}.0/24 via ${PROXY_GATEWAY}"
  sudo ip route add 10.5."${i}".0/24 via ${PROXY_GATEWAY} dev eth0 || echo "Route to 10.5.${i}.0/24 may already exist"

done

step_log "Using Azure UDR for 10.2.x.0/24 reachability"

# Add all proxy subnet IPs on the primary 10.3.* interface
step_log "Adding proxy subnet IP aliases"
primary_if=$(ip -o -4 addr | awk '$4 ~ /^10\.3\./ {print $2; exit}')
if [ -z "$primary_if" ]; then
  echo "ERROR: Could not find interface with 10.3.* address"
  exit 1
fi
for i in $(seq 6 254); do
  sudo ip addr add "10.3.$((PROXY_NODE_ID + 1)).${i}/24" dev "$primary_if" 2>/dev/null || true
done

# Enable forwarding only; per-IP DNAT/SNAT is intentionally not used.
step_log "Configuring routing mode (no per-IP NAT)"
sudo sysctl -w net.ipv4.ip_forward=1

make -j

# Update the hostname (used as node name in k8s)
until sudo hostnamectl set-hostname "proxy-${PROXY_ID}"
do
  echo "Failed to set hostname..."
  sleep 5
done

# Copy common_k0.sh to /tmp for worker_install_k0.sh to source
cp $AZURE_USER_HOME/instance_scripts/common_k0.sh /tmp/common_k0.sh

# Join the k8s cluster as a worker using direct route to the controller VM.
step_log "Joining k8s cluster as worker (proxy-${PROXY_ID})"
bash $AZURE_USER_HOME/instance_scripts/worker_install_k0.sh 10.2.0.7
