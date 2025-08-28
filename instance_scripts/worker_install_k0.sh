#!/usr/bin/env bash
# Usage: sudo ./worker_install_k0s.sh <controller_ip>
set -euo pipefail
CTL_IP=${1:? "controller IP required"}
LOG_FILE="/home/ubuntu/k0s_worker.log"
source /tmp/common_k0.sh

install_deps
install_k0s

if ! command -v sshpass >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y sshpass
fi

remote="ubuntu@${CTL_IP}:~/token-file"
target="/home/ubuntu/token-file"
delay=5
max_attempts=10000
attempt=1
password="1997"

while (( attempt <= max_attempts )); do
  [[ -f $target ]] && {
    echo "✓ $target is present; done."
    break
  }

  echo "Attempt $attempt: Attempting to copy token-file..."
  if sshpass -p "$password" scp -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$remote" "$target"; then
    echo "✓ Copy succeeded."
    break
  else
    if (( attempt == max_attempts )); then
      echo "❌ Reached max attempts ($max_attempts). Exiting."
      exit 1
    fi
    echo "⚠️  token-file not found on controller or copy failed; retrying in $delay s..."
    sleep "$delay"
    ((attempt++))
  fi
done

log "Joining cluster with token"
sudo k0s install worker --token-file  /home/ubuntu/token-file>>"$LOG_FILE"
sudo k0s start
