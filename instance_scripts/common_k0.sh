#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

LOG_DIR="/home/ubuntu"
K0S_VERSION="v1.27.13+k0s.0"
K0S_BIN="/usr/local/bin/k0s"

log()  { echo -e "[\e[34mINFO\e[0m] $*" | tee -a "$LOG_FILE"; }
fail() { echo -e "[\e[31mFAIL\e[0m] $*" | tee -a "$LOG_FILE"; exit 1; }

install_deps() {
  # Retry until iperf3 is confirmed installed
  # (workaround for unattended-upgrades holding the dpkg lock)
  until apt list --installed 2>/dev/null | grep -q iperf3; do
    install_deps_single
  done
}

install_deps_single() {
  log "Installing prerequisites"
  sudo apt-get update -qq || true
  sudo apt-get install -yqq curl conntrack socat ebtables iptables iputils-ping nano iperf3 libsctp-dev lksctp-tools zlib1g-dev sshpass || true
  sudo modprobe sctp || true
  log "Enabling br_netfilter (which needs to be done manually now for some unknown reason...)"
  sudo modprobe br_netfilter
  echo "br_netfilter" | sudo tee /etc/modules-load.d/br_netfilter.conf
  log "Installing Helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >>"$LOG_FILE"
}

install_k0s() {
  log "Installing k0s ($K0S_VERSION)"
  curl -sSLf https://get.k0s.sh | sudo K0S_VERSION="$K0S_VERSION" sh >> "$LOG_FILE"
  # Download and install the standard CNI plugins
  sudo mkdir -p /opt/cni/bin
  curl -L https://github.com/containernetworking/plugins/releases/download/v1.4.0/cni-plugins-linux-amd64-v1.4.0.tgz \
    | sudo tar -xz -C /opt/cni/bin

  # Provide kubectl command by forwarding to k0s kubectl.
  # This avoids requiring users to type "k0s kubectl" everywhere.
  if ! command -v kubectl >/dev/null 2>&1; then
    log "Installing kubectl shim (k0s kubectl wrapper)"
    sudo tee /usr/local/bin/kubectl >/dev/null <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/k0s kubectl "$@"
EOF
    sudo chmod +x /usr/local/bin/kubectl
  fi
}

wait_for_token() {         # $1 = controller_ip
  local ctl_ip="$1"; local token=""
  log "Waiting for join token from $ctl_ip ..."
  for _ in {1..30}; do
      token=$(ssh -oStrictHostKeyChecking=no ubuntu@"$ctl_ip" cat /home/ubuntu/token-file 2>/dev/null || true)
      [[ -n "$token" ]] && { echo "$token"; return 0; }
      sleep 5
  done
  return 1
}

