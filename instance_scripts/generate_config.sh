#!/usr/bin/env bash
# gen-node-maps.sh  <node-count>  [output-file]
#
# Example:
#   sudo bash gen-node-maps.sh 4        # → nodes.json
#   sudo bash gen-node-maps.sh 3  map.json
#
# Result (truncated):
# {
#   "node1": {
#     "192.168.1.2": "192.168.10.2",
#     ...
#     "192.168.1.254": "192.168.10.254"
#   },
#   "node2": {
#     "192.168.2.2": "192.168.11.2",
#     ...
#   },
#   ...
# }
set -euo pipefail

nodes=${1:-1}               # how many node blocks to emit
outfile=${2:-nodes.json}    # destination file

# open the root object

for node in $(seq 0  $((nodes - 1))); do
    right_net=$node
    left_net=$(( node  ))

    # Get hostname and strip trailing number
    host=$(hostname)
    base_host=${host%%[0-9]*}  # Removes everything from first digit onwards

    # open this node’s object
    printf '%s%d: {' "$base_host" "$((node ))" >> "$outfile"
  # open this node’s object
  printf 'node%d: {' "$((node))" >> "$outfile"

  for host in $(seq 6 254); do
    left_ip="10.1.${left_net}.${host}"
    right_ip="10.2.${right_net}.${host}"
    # print a "key":"value" pair
    printf '    "%s": "%s"' "$left_ip" "$right_ip" >> "$outfile"
    # comma between pairs except after .254
    [[ $host -lt 254 ]] && printf ',' >> "$outfile"
  done
  printf '  }' >> "$outfile"
  printf ',\n' >> "$outfile"
done


echo "✅  Generated: $outfile"
