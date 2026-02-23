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

make -j

# Update the hostname (used as node name in k8s)
until sudo hostnamectl set-hostname "proxy-${PROXY_ID}"
do
  echo "Failed to set hostname..."
  sleep 5
done

# Copy common_k0.sh to /tmp for worker_install_k0.sh to source
cp $AZURE_USER_HOME/instance_scripts/common_k0.sh /tmp/common_k0.sh

# Join the k8s cluster as a worker
# 10.1.0.7 is the registered secondary IP on ins0's NIC, DNAT'd to the controller QEMU VM (10.2.0.7)
step_log "Joining k8s cluster as worker (proxy-${PROXY_ID})"
bash $AZURE_USER_HOME/instance_scripts/worker_install_k0.sh 10.1.0.7
