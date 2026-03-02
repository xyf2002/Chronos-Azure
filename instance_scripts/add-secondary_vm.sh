#!/usr/bin/env bash
#
# add-secondary_vm.sh
# Adds .8-.254/24 on the inner VM interface that owns *.7/24.
# Can also install a systemd oneshot service to re-apply on every reboot.
set -euo pipefail

SERVICE_NAME="chronos-add-secondary-vm.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
INSTALL_PATH="/usr/local/sbin/chronos-add-secondary-vm.sh"

apply_secondary_ips() {
  local primary_if
  local prefix

  primary_if=$(ip -o -4 addr | awk '$4 ~ /\.7\/24$/ {print $2; exit}')
  if [[ -z "$primary_if" ]]; then
    echo "Could not find an interface with x.x.x.7/24" >&2
    return 1
  fi

  prefix=$(ip -o -4 addr show "$primary_if" | awk '$4 ~ /\.7\/24$/ {sub(/\.7\/24/,"",$4); print $4}')
  if [[ -z "$prefix" ]]; then
    echo "Could not derive /24 prefix from ${primary_if}" >&2
    return 1
  fi

  echo "Interface: ${primary_if}  Network: ${prefix}.0/24"
  for i in $(seq 8 254); do
    ip addr add "${prefix}.${i}/24" dev "$primary_if" 2>/dev/null || true
  done
}

install_reboot_service() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Install mode must run as root (use sudo)." >&2
    return 1
  fi

  local src
  src=$(readlink -f "$0")
  install -m 0755 "$src" "$INSTALL_PATH"

  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Chronos inner VM secondary IP setup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} --apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  echo "Installed and enabled ${SERVICE_NAME}"
}

case "${1:-}" in
  --apply)
    apply_secondary_ips
    ;;
  --install-service)
    install_reboot_service
    ;;
  "")
    apply_secondary_ips
    ;;
  *)
    echo "Usage: $0 [--apply|--install-service]" >&2
    exit 1
    ;;
esac
