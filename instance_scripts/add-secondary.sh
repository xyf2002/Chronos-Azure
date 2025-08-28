#!/usr/bin/env bash
#

# add-secondary-ips-eth.sh
#
# For every interface whose name matches ^eth, add the secondary
# addresses .6-.254 with the same prefix-length as the primary address.
# Starts from .6 since Azure typically uses .4 and .5 for gateway and primary IP.
#
# Run with sudo.

set -euo pipefail

echo "Searching for eth interfaces..."

# Pull (iface  primary/CIDR) pairs for eth* interfaces
while IFS=' ' read -r iface cidr; do
  primary=${cidr%/*}        # e.g. 10.1.0.5
  mask=${cidr#*/}           # e.g. 24
  prefix=${primary%.*}      # e.g. 10.1.0

  echo "==> $iface  $primary/$mask  —  adding ${prefix}.6-254 (Azure optimized range)"

  for host in $(seq 6 254); do
    # Skip the primary IP address
    if [ "${prefix}.${host}" = "$primary" ]; then
      echo "     ${prefix}.${host} (primary, skipping)"
      continue
    fi

    ip addr add "${prefix}.${host}/${mask}" dev "$iface" 2>/dev/null \
      && echo "   + ${prefix}.${host}" \
      || echo "     ${prefix}.${host} already present or failed"
  done
done < <(
  # one line per eth interface with an IPv4 address
  ip -o -4 addr show | awk '$2 ~ /^eth0/ {print $2, $4}' | head -10
)

echo "Secondary IP assignment completed."
