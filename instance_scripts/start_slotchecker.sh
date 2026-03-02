#!/bin/bash
set -euo pipefail

# Extract numeric ID from hostname, then subtract 1 (e.g., ins0 -> -1, ins1 -> 0)
HOST_NUM=$(hostname | grep -o '[0-9]\+' | head -n1 || true)
if [ -z "${HOST_NUM:-}" ]; then
  echo "Could not derive numeric id from hostname: $(hostname)" >&2
  exit 1
fi
C_ID=$((HOST_NUM - 1))
SHM_FILE="/dev/shm/my-little-shared-memory"
INIT_BIN="$HOME/fake_tsc/init"
SLOTCHECKER_BIN="$HOME/instance_scripts/slotcheckerservice"

if [ ! -x "$SLOTCHECKER_BIN" ]; then
  echo "slotcheckerservice binary not found: $SLOTCHECKER_BIN" >&2
  exit 1
fi

# /dev/shm is tmpfs and gets cleared on reboot; recreate shared memory before starting.
if [ ! -e "$SHM_FILE" ]; then
  echo "Shared memory file missing ($SHM_FILE); running init..."
  cd /home/azureuser/fake_tsc
  sudo insmod custom_tsc.ko; sudo modprobe kvm; sudo modprobe kvm_intel; sudo ./init; sudo ./init
  if [ -x "$INIT_BIN" ]; then
    sudo "$INIT_BIN"
  fi
fi

if [ ! -e "$SHM_FILE" ]; then
  echo "Shared memory file still missing ($SHM_FILE)." >&2
  echo "Run: sudo $INIT_BIN" >&2
  exit 1
fi

# ins0 maps to C_ID=-1; skip running slotchecker there.
if [ "$C_ID" -lt 0 ]; then
  echo "Skipping slotcheckerservice on $(hostname): computed C_ID=${C_ID}"
  exec sleep infinity
fi

# Run the main binary with (hostname numeric id - 1)
exec sudo taskset -c 2 chrt -f 99 "$SLOTCHECKER_BIN" "$C_ID"
