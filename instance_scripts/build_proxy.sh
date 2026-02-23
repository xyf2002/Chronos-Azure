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
GITHUB_TOKEN="$1"
NUM_MACHINE="$2"
GITHUB_USERNAME="$3"
PROXY_ID="${4:-0}"          # proxy index (0, 1, 2, ...), default 0

PROXY_GATEWAY="10.3.$((PROXY_ID+1)).1"

echo "Proxy ID: ${PROXY_ID}, Gateway: ${PROXY_GATEWAY}"

kernel_repo="andrewferguson/phobos-proxy"
  sudo apt update
  sudo apt-get install -yqq libsctp-dev lksctp-tools  zlib1g-dev
  sudo modprobe sctp
phobos_link="https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/${kernel_repo}.git"
git clone --quiet "${phobos_link}" $AZURE_USER_HOME/phobos-proxy
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
