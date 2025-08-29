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
kernel_repo="andrewferguson/phobos-proxy"
  sudo apt update 
  sudo apt-get install -yqq libsctp-dev lksctp-tools  zlib1g-dev
  sudo modprobe sctp
phobos_link="https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/${kernel_repo}.git"
git clone --quiet "${phobos_link}" $AZURE_USER_HOME/phobos-proxy
cd $AZURE_USER_HOME/phobos-proxy

# Add routes to instance networks
# Proxy (10.4.1.5) needs to route to instance networks (10.1.x.x and 10.3.x.x)
# The gateway for proxy subnet 10.4.1.0/24 is 10.4.1.1
for (( i=0; i<NUM_MACHINE; i++ )); do
  # Route to first NIC subnet (10.1.i.0/24) via proxy subnet gateway
  echo "Adding route: 10.1.${i}.0/24 via 10.4.1.1"
  sudo ip route add 10.1."${i}".0/24 via 10.4.1.1 dev eth0 || echo "Route to 10.1.${i}.0/24 may already exist"

  # Route to second NIC subnet (10.3.i.0/24) via proxy subnet gateway
  echo "Adding route: 10.3.${i}.0/24 via 10.4.1.1"
  sudo ip route add 10.3."${i}".0/24 via 10.4.1.1 dev eth0 || echo "Route to 10.3.${i}.0/24 may already exist"
done

make -j
