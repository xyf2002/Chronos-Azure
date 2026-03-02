#!/bin/bash
set -euo pipefail

# Default values mirror the working command sequence from live debugging.
HOST_IF="${HOST_IF:-eth0}"
VM_BR="${VM_BR:-virbr0}"

# Try to infer the inner VM subnet from virbr0 (e.g., 10.2.0.1/24 -> 10.2.0.0/24).
if [ -n "${VM_SUBNET_CIDR:-}" ]; then
INNER_SUBNET="$VM_SUBNET_CIDR"
else
BR_CIDR=$(ip -o -4 addr show "$VM_BR" 2>/dev/null | awk 'NR==1 {print $4}')
if [ -n "$BR_CIDR" ]; then
INNER_SUBNET=$(ip route show dev "$VM_BR" | awk '/proto kernel/ {print $1; exit}')
else
INNER_SUBNET="10.2.0.0/24"
fi
fi

insert_rule_once() {
local chain="$1"
shift
if ! sudo iptables -C "$chain" "$@" 2>/dev/null; then
sudo iptables -I "$chain" 1 "$@"
fi
}

echo "Applying runtime sysctl forwarding/rp_filter settings"
sudo sysctl -w net.ipv4.ip_forward=1
sudo sysctl -w net.ipv4.conf.all.rp_filter=2
sudo sysctl -w "net.ipv4.conf.${HOST_IF}.rp_filter=2"
sudo sysctl -w "net.ipv4.conf.${VM_BR}.rp_filter=2"

echo "Applying FORWARD rules for ${HOST_IF} <-> ${VM_BR} on ${INNER_SUBNET}"
insert_rule_once FORWARD -i "$HOST_IF" -o "$VM_BR" -d "$INNER_SUBNET" -j ACCEPT
insert_rule_once FORWARD -i "$VM_BR" -o "$HOST_IF" -s "$INNER_SUBNET" -j ACCEPT
insert_rule_once FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

echo "Applying LIBVIRT_FW* top rules (if chains exist)"
for c in LIBVIRT_FWX LIBVIRT_FWI LIBVIRT_FWO; do
sudo iptables -nL "$c" >/dev/null 2>&1 || continue
insert_rule_once "$c" -i "$HOST_IF" -o "$VM_BR" -d "$INNER_SUBNET" -j ACCEPT
insert_rule_once "$c" -i "$VM_BR" -o "$HOST_IF" -s "$INNER_SUBNET" -j ACCEPT
insert_rule_once "$c" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
done    
echo "IP forwarding and iptables rules applied successfully"


