#!/bin/bash
exec >> $HOME/build.log
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
kernel_repo="andrewferguson/phobos-proxy"
  sudo apt update 
  sudo apt-get install -yqq libsctp-dev lksctp-tools  zlib1g-dev
  sudo modprobe sctp
phobos_link="https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/${kernel_repo}.git"
git clone --quiet "${phobos_link}" ~/phobos-proxy
cd ~/phobos-proxy

# Add routes to instance networks
# Proxy (10.4.1.1) needs to route to instance networks (10.1.x.x and 10.3.x.x)
for (( i=0; i<NUM_MACHINE; i++ )); do
  # Route to first NIC subnet (10.1.i.0/24) via main gateway
  echo "Adding route: 10.1.${i}.0/24 via 10.4.1.1"
  sudo ip route add 10.1."${i}".0/24 via 10.0.1.1 dev eth0 || echo "Route to 10.1.${i}.0/24 may already exist"

  # Route to second NIC subnet (10.3.i.0/24) via main gateway
  echo "Adding route: 10.3.${i}.0/24 via 10.0.1.1"
  sudo ip route add 10.3."${i}".0/24 via 10.0.1.1 dev eth0 || echo "Route to 10.3.${i}.0/24 may already exist"
done

make -j
