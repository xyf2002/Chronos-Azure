#!/usr/bin/env bash
set -euo pipefail
LOG_FILE="/home/ubuntu/k0s_master.log"
source /tmp/common_k0.sh

install_deps
install_k0s

log "Installing controller service"
k0s config create > k0s.yaml
sed -i 's/^    provider: kuberouter$/    provider: custom/' k0s.yaml
log "configuring controller"
sudo k0s install controller -c k0s.yaml --enable-worker
sleep 1
log "starting k0s"
sudo k0s start

dest=/home/ubuntu/token-file   # final location
delay=5                        # seconds between attempts

while :; do
  echo "⇒ Requesting worker token …"
  token=$(sudo k0s token create --role=worker --expiry=100h || true)

  if [[ -n $token ]]; then           # non-empty?
    printf '%s\n' "$token" > "$dest"
    echo "✓ Token saved to $dest"
    break
  else
    echo "⚠️  k0s returned an empty token; retrying in $delay s …"
    sleep "$delay"
  fi
done
sudo k0s kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
sudo cp /var/lib/k0s/pki/admin.conf ~/admin.conf
echo 'export KUBECONFIG=~/admin.conf' >> ~/.bashrc
sudo chown ubuntu ~/admin.conf
chmod g-r ~/admin.conf
sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq && sudo chmod +x /usr/bin/yq
echo -e '#!/bin/bash\nexec k0s kubectl "$@"' | sudo tee /usr/local/bin/kubectl > /dev/null
sudo chmod +x /usr/local/bin/kubectl
kubectl taint nodes ins0vm node-role.kubernetes.io/control-plane-
#Generate and save Worker token
log "Worker join-token written to /home/ubuntu/token-file"
