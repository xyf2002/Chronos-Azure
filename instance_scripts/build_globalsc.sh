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

# Add routes to QEMU VM subnets via each compute VM's first NIC
# 10.1.i.5 is the primary IP of ins(i)'s NIC1; iptables on that VM DNAT's 10.1.i.x -> 10.2.i.x
for (( i=0; i<NUM_OUTER_NODES; i++ )); do
    echo "Adding route: 10.2.${i}.0/24 via 10.1.${i}.5"
    sudo ip route add 10.2."${i}".0/24 via 10.1."${i}".5 || echo "Route to 10.2.${i}.0/24 may already exist"
done

# Enable forwarding and add DNAT/SNAT rules so globalsc can reach all inner VMs
step_log "Configuring DNAT/SNAT rules for inner VMs"
sudo sysctl -w net.ipv4.ip_forward=1
for (( i=0; i<NUM_OUTER_NODES; i++ )); do
    INNER_IP="10.2.${i}.7"
    OUTER_IP="10.1.${i}.7"
    echo "Adding NAT rules: ${INNER_IP} -> ${OUTER_IP}"

    sudo iptables -t nat -C OUTPUT -d "${INNER_IP}/32" -j DNAT --to-destination "${OUTER_IP}" 2>/dev/null || \
        sudo iptables -t nat -I OUTPUT 1 -d "${INNER_IP}/32" -j DNAT --to-destination "${OUTER_IP}"
    sudo iptables -t nat -C PREROUTING -d "${INNER_IP}/32" -j DNAT --to-destination "${OUTER_IP}" 2>/dev/null || \
        sudo iptables -t nat -I PREROUTING 1 -d "${INNER_IP}/32" -j DNAT --to-destination "${OUTER_IP}"
    sudo iptables -t nat -C POSTROUTING -d "${OUTER_IP}/32" -j MASQUERADE 2>/dev/null || \
        sudo iptables -t nat -I POSTROUTING 1 -d "${OUTER_IP}/32" -j MASQUERADE
done

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

# Join the k8s cluster as a worker
# 10.1.0.7 is the registered secondary IP on ins0's NIC1, DNAT'd to the controller QEMU VM (10.2.0.7)
step_log "Joining k8s cluster as worker (globalsc)"
bash $AZURE_USER_HOME/instance_scripts/worker_install_k0.sh 10.1.0.7
