#!/bin/bash

# Extract numeric ID from hostname, e.g., node0 → 0
C_ID=$(hostname | grep -o '[0-9]\+')

# Run the main binary with extracted c_id
sudo taskset -c 2 chrt -f 99 $HOME/scripts/slotcheckerservice "$C_ID"
