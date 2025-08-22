#!/usr/bin/env bash
#

# add-secondary-ips-vlan.sh
#
# For every interface whose name matches ^vlan, add the secondary
# addresses .2-.254 with the same prefix-length as the primary address.
#
# Run with sudo.

set -euo pipefail

# Pull (iface  primary/CIDR) pairs for vlan* interfaces
while IFS=' ' read -r iface cidr; do
  primary=${cidr%/*}        # e.g. 192.168.1.1
  mask=${cidr#*/}           # e.g. 16
  prefix=${primary%.*}      # e.g. 192.168.1

  echo "==> $iface  $primary/$mask  —  adding ${prefix}.2-254"

  for host in $(seq 2 254); do
    ip addr add "${prefix}.${host}/${mask}" dev "$iface" 2>/dev/null \
      && echo "   + ${prefix}.${host}" \
      || echo "     ${prefix}.${host} already present or failed"
  done
done < <(
  # one line per vlan interface with an IPv4 address
  ip -o -4 addr show | awk '$2 ~ /^vlan/ {print $2, $4}'
)