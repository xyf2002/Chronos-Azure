#!/usr/bin/env bash
#
# add-secondary-ips.sh
# Adds .3-.254/24 to whichever interface already has *.2/24.
# Run with sudo.
set -euo pipefail

# 1. Discover the interface that owns *.2
primary_if=$(ip -o -4 addr \
               | awk '$4 ~ /\.6\/24$/ {print $2; exit}')
[[ -z $primary_if ]] && {
  echo "Couldn’t find an interface with x.x.x.6/24" >&2
  exit 1
}

# 2. Derive the /24 network prefix (e.g. 192.168.10)
prefix=$(ip -o -4 addr show "$primary_if" \
           | awk '$4 ~ /\.7\/24$/ {sub(/\.7\/24/,"",$4); print $4}')

echo "Interface: $primary_if  —  Network: ${prefix}.0/24"

# 3. Add .6-.254
for i in $(seq 8 254); do
  ip addr add "${prefix}.${i}/24" dev "$primary_if" 2>/dev/null \
    && echo "Added ${prefix}.${i}" \
    || echo "⚠️  ${prefix}.${i} already present or failed"
done
