#!/bin/bash

AZURE_USER_HOME="/home/azureuser"

exec >> $AZURE_USER_HOME/build.log
exec 2>&1

function step_log() {
    echo ""
    echo "====================[ $1 ]===================="
    date
    if [ -n "${2:-}" ]; then
        echo ""
        echo "$2"
    fi
    echo ""
}

NUM_OUTER_NODES="$1"

sudo apt update
sudo apt-get install -yqq libsctp-dev lksctp-tools zlib1g-dev
sudo modprobe sctp

step_log "Using Azure UDR for 10.2.x.0/24 reachability"

# Enable forwarding only; per-IP DNAT/SNAT is intentionally not used.
step_log "Configuring routing mode (no per-IP NAT)"
sudo sysctl -w net.ipv4.ip_forward=1

# Setup ssh keys
ssh-keygen -q -t rsa -N '' -f $AZURE_USER_HOME/.ssh/id_rsa 2>/dev/null || true
grep -qF "$(cat $AZURE_USER_HOME/.ssh/id_rsa.pub)" $AZURE_USER_HOME/.ssh/authorized_keys 2>/dev/null || \
    cat $AZURE_USER_HOME/.ssh/id_rsa.pub >> $AZURE_USER_HOME/.ssh/authorized_keys

# Update the hostname (used as node name in k8s)
until sudo hostnamectl set-hostname "globalsc"
do
    echo "Failed to set hostname..."
    sleep 5
done

# Copy common_k0.sh to /tmp for worker_install_k0.sh to source
cp $AZURE_USER_HOME/instance_scripts/common_k0.sh /tmp/common_k0.sh

# Join the k8s cluster as a worker using direct route to the controller VM.
step_log "Joining k8s cluster as worker (globalsc)"
bash $AZURE_USER_HOME/instance_scripts/worker_install_k0.sh 10.2.0.7
