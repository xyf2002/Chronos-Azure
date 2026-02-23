#!/usr/bin/env bash
# Usage: sudo ./worker_install_k0s.sh <controller_ip>
set -euo pipefail
CTL_IP=${1:? "controller IP required"}
USER_HOME="${HOME:-}"
if [ -z "$USER_HOME" ]; then
  USER_HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"
fi
[ -n "$USER_HOME" ] || USER_HOME="/tmp"
LOG_FILE="${USER_HOME}/k0s_worker.log"
if [ ! -f "/tmp/common_k0.sh" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "${SCRIPT_DIR}/common_k0.sh" ] && cp "${SCRIPT_DIR}/common_k0.sh" /tmp/common_k0.sh
fi
source /tmp/common_k0.sh

install_deps
install_k0s

if ! command -v sshpass >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y sshpass
fi

remote="ubuntu@${CTL_IP}:~/token-file"
target="${USER_HOME}/token-file"
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
LABEL_ARGS=""
if [[ "$HOSTNAME" == "ins"* ]]; then
  LABEL_ARGS='--labels "dilated=true"'
fi
sudo k0s install worker --token-file "${USER_HOME}/token-file" --kubelet-extra-args="--max-pods=243 --node-status-update-frequency=1s" $LABEL_ARGS >>"$LOG_FILE"
sudo k0s start
