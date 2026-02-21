#!/bin/bash
# Dry-run of build_instance.sh — logs all commands that would be executed
# without modifying the system.
# Usage: bash build_instance_dry_run.sh INSTANCE_ID INSTANCE_COUNT
# Output: /home/azureuser/dry_run.log

INSTANCE_ID="$1"
MACHINE_NUM="$2"

DRY_RUN_LOG="/home/azureuser/dry_run.log"
# Use a temp dir for flag files so all steps flow through
AZURE_USER_HOME="/tmp/dry_run_inst${INSTANCE_ID}"
mkdir -p "$AZURE_USER_HOME"
> "$DRY_RUN_LOG"

exec > >(tee -a "$DRY_RUN_LOG") 2>&1
echo "=== DRY RUN START: $(date) ==="
echo "=== Log: $DRY_RUN_LOG ==="

# ── Network variables (same as build_instance.sh) ───────────────────────────
INTERNAL_SUBNET=$((INSTANCE_ID))
INTERNAL_IP="10.2.${INTERNAL_SUBNET}.7"
NET_GW_IP="10.2.${INTERNAL_SUBNET}.1"
RANGE_START="10.2.${INTERNAL_SUBNET}.2"
RANGE_END="10.2.${INTERNAL_SUBNET}.254"
EXPOSED_IP="10.1.${INSTANCE_ID}.1"
VM_NAME="ins${INSTANCE_ID}vm"

echo "Instance_ID: ${INSTANCE_ID}, MACHINE_NUM: ${MACHINE_NUM}"
echo "Internal Subnet: 10.2.${INTERNAL_SUBNET}.0/24, Internal IP: ${INTERNAL_IP}"
echo "VM Name: ${VM_NAME}"

# ── Helper ───────────────────────────────────────────────────────────────────
step_log() {
    echo ""
    echo "====== $1 ======"
    date
    [ -n "$2" ] && echo "$2"
    echo ""
}

log_cmd() { echo "[DRY-RUN] $*"; }

# ── Command overrides ────────────────────────────────────────────────────────

# sleep: skip waits in dry-run
sleep() { log_cmd "sleep $*"; }

# ssh-keygen / ssh-copy-id
ssh-keygen() { log_cmd "ssh-keygen $*"; }
ssh-copy-id() { log_cmd "ssh-copy-id $*"; }

# git / gcc / make / scp / ssh / sshpass
git()     { log_cmd "git $*"; }
gcc()     { log_cmd "gcc $*"; }
make()    { log_cmd "make $*"; }
scp()     { log_cmd "scp $*"; }
ssh()     { log_cmd "ssh $*"; }
sshpass() { log_cmd "sshpass $*"; }

# sudo: log the command; mock outputs needed for conditional logic
sudo() {
    log_cmd "sudo $*"
    case "$*" in
        # virsh dominfo: return 1 so script enters "create VM" branch
        "virsh dominfo "*)
            return 1
            ;;
        # virsh domifaddr: return fake MAC/IP so REAL_MAC is populated
        "virsh domifaddr "*)
            echo " vnet0      52:54:00:ab:cd:ef  ipv4  10.2.${INTERNAL_SUBNET}.100/24"
            ;;
        # virsh domstate: return "running" to exit wait loops immediately
        "virsh domstate "*)
            echo "running"
            ;;
        # virsh net-info: return 0 so net-define is skipped
        "virsh net-info default")
            return 0
            ;;
        # grep -q on NET_XML: return 1 so the sed/dhcp-host block runs
        "grep -q "*)
            return 1
            ;;
    esac
    return 0
}

# ── Step 0: Initialization ───────────────────────────────────────────────────
step_log "Step 0: Initialization" "Starting integrated build_kernel process"
touch "$AZURE_USER_HOME/.kernel_done" "$AZURE_USER_HOME/.rebooted"

# ── Step 1: Kernel Build (already done) ──────────────────────────────────────
step_log "Step 1: Kernel Build, already done"
touch "$AZURE_USER_HOME/.kernel_done"
touch "$AZURE_USER_HOME/.rebooted"

# ── Step 2: Build & insert fake_tsc ──────────────────────────────────────────
if [ -f "$AZURE_USER_HOME/.kernel_done" ] && [ -f "$AZURE_USER_HOME/.rebooted" ] && [ ! -f "$AZURE_USER_HOME/.tsc_done" ]; then
    step_log "Step 2: After reboot - Build and insert fake_tsc module" ""
    rm -f "$AZURE_USER_HOME/.rebooted"

    wait_for_lock() {
        while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
            echo "Waiting for dpkg lock to be released..."
            sleep 5
        done
    }
    wait_for_lock
    sudo -S apt-get update -y
    sudo -S apt-get install -y build-essential linux-headers-$(uname -r)

    log_cmd "[ check ] fake_tsc dir exists? → would clone if missing"
    git clone "https://github.com/ujjwalpawar/fake_tsc.git"

    log_cmd "[ check ] init.c exists? → would compile"
    gcc init.c -o init
    log_cmd "[ check ] shared.c exists? → would compile"
    gcc shared.c -o shared

    step_log "Building fake_tsc module"
    sudo make -C /lib/modules/$(uname -r)/build M=/home/azureuser/fake_tsc modules

    step_log "Inserting custom_tsc.ko"
    sudo insmod custom_tsc.ko
    sudo modprobe kvm
    sudo modprobe kvm_intel
    sudo ./init
    sudo ./init

    step_log "Installing additional libs and verifying fake_tsc module"
    sudo apt-get install -yqq libsctp-dev lksctp-tools zlib1g-dev
    sudo modprobe sctp
    sudo lsmod
    sudo dmesg

    gcc slotcheckerservice.c -o slotcheckerservice
    touch "$AZURE_USER_HOME/.tsc_done"
fi

# ── Step 3: VM Setup ──────────────────────────────────────────────────────────
step_log "Step 3: VM Setup"
if [ -f "$AZURE_USER_HOME/.tsc_done" ] && [ ! -f "$AZURE_USER_HOME/.vm_setup_done" ]; then
    step_log "Installing virtualization tools and creating VM (uvt-kvm + static MAC)"

    sudo apt-get update
    sudo apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst uvtool iptables

    step_log "Syncing Ubuntu cloud image"
    sudo uvt-simplestreams-libvirt sync --source https://cloud-images.ubuntu.com/daily/ release=focal arch=amd64

    sudo update-alternatives --install /usr/sbin/iptables iptables /usr/sbin/iptables-legacy 10
    sudo update-alternatives --install /usr/sbin/ip6tables ip6tables /usr/sbin/ip6tables-legacy 10
    sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
    sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
    sudo apt-get install -y arptables ebtables
    sudo update-alternatives --install /usr/sbin/arptables arptables /usr/sbin/arptables-legacy 10
    sudo update-alternatives --install /usr/sbin/ebtables ebtables /usr/sbin/ebtables-legacy 10
    sudo update-alternatives --set arptables /usr/sbin/arptables-legacy
    sudo update-alternatives --set ebtables /usr/sbin/ebtables-legacy
    sudo systemctl restart libvirtd

    sudo iptables -t filter -N LIBVIRT_INP
    sudo iptables -t filter -N LIBVIRT_OUT
    sudo iptables -t filter -N LIBVIRT_FWO
    sudo iptables -t filter -N LIBVIRT_FWI
    sudo iptables -t filter -N LIBVIRT_FWX

    if ! sudo virsh net-info default >/dev/null 2>&1; then
        sudo virsh net-define /usr/share/libvirt/networks/default.xml
    fi
    sudo virsh net-start default

    step_log "VM  = ${VM_NAME}"
    step_log "Int = ${INTERNAL_IP}"

    if sudo virsh dominfo "${VM_NAME}" >/dev/null 2>&1; then
        step_log "VM ${VM_NAME} already exists, skipping creation"
    else
        step_log "Creating new VM ${VM_NAME}"
        sudo uvt-kvm create "${VM_NAME}" release=focal arch=amd64 --cpu 2 --memory 4096 --password 1997

        step_log "Modifying /etc/libvirt/qemu/${VM_NAME}.xml to patch CPU and clock settings"
        VM_XML="/etc/libvirt/qemu/${VM_NAME}.xml"
        TMP_XML="/tmp/${VM_NAME}.xml.modified"
        sudo cp "$VM_XML" "$VM_XML.bak"

        step_log "Deleting two lines after </features>"
        sudo awk '/<\/features>/ { print; skip=2; next } skip>0 { skip--; next } { print }' "$VM_XML"

        step_log "Inserting new <cpu> and <clock> blocks"
        sudo sed -i "/<\/features>/a ..." "$TMP_XML"

        step_log "Replacing ${VM_NAME}.xml and redefining domain"
        sudo mv "$TMP_XML" "$VM_XML"
        sudo virsh define "$VM_XML"
        sudo virsh destroy "$VM_NAME"
        sudo virsh start "$VM_NAME"
    fi

    step_log "Waiting domifaddr for ${VM_NAME}"
    domif=$(sudo virsh domifaddr "$VM_NAME" 2>&1)
    step_log "domifaddr output" "$domif"
    REAL_MAC=$(echo "$domif" | awk '/ipv4/ {print $2}')
    echo "REAL_MAC resolved to: ${REAL_MAC}"

    if [ -z "$REAL_MAC" ]; then
        echo "❌ domifaddr did not return MAC, aborting"; exit 1
    fi

    step_log "Edit the default network"
    NET_XML="/etc/libvirt/qemu/networks/default.xml"
    if ! sudo grep -q "$REAL_MAC" "$NET_XML"; then
        step_log "Adding DHCP host entry for ${VM_NAME}: gw=${NET_GW_IP} range=${RANGE_START}-${RANGE_END} ip=${INTERNAL_IP} mac=${REAL_MAC}"
        sudo sed -i "..." "$NET_XML"
    fi

    step_log "stopping ${VM_NAME} to change ip address"
    sudo virsh shutdown "${VM_NAME}"

    state=$(sudo virsh domstate "${VM_NAME}" 2>/dev/null) || state="unknown"
    echo "VM state after shutdown: ${state}"

    sudo virsh net-destroy default
    sudo service libvirtd restart
    sudo systemctl restart libvirtd
    sudo virsh net-start default
    sudo virsh start "${VM_NAME}"

    state=$(sudo virsh domstate "${VM_NAME}" 2>/dev/null) || state="unknown"
    echo "VM state after start: ${state}"

    step_log "Waiting for ${VM_NAME} to get IP ${INTERNAL_IP}"
    log_cmd "virsh domifaddr ${VM_NAME}  →  would wait for ${INTERNAL_IP}"

    touch "$AZURE_USER_HOME/.vm_setup_done"
fi

# ── Step 4: Exposed-IP alias & NAT rules ─────────────────────────────────────
if [ -f "$AZURE_USER_HOME/.vm_setup_done" ] && [ ! -f "$AZURE_USER_HOME/.net_setup_done" ]; then
    step_log "Setting alias IP and NAT rules for this host"

    state=$(sudo virsh domstate "${VM_NAME}" 2>/dev/null) || true
    echo "VM state: ${state}"

    step_log "Adding secondary IPs on host"
    sudo /home/azureuser/instance_scripts/add-secondary.sh

    step_log "Generating nodes.json for ${MACHINE_NUM} machines"
    sudo /home/azureuser/instance_scripts/generate_config.sh "${MACHINE_NUM}"

    step_log "Applying iptables NAT rules from nodes.json"
    sudo /home/azureuser/instance_scripts/set_ip.sh

    sudo apt-get -y install sshpass

    step_log "SSH key setup"
    ssh-keygen -q -t rsa -N '' -f /home/azureuser/.ssh/id_rsa
    sshpass -p 1997 ssh-copy-id -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null ubuntu@${INTERNAL_IP}

    step_log "Copy add-secondary_vm.sh to QEMU VM (${INTERNAL_IP}) and run it"
    scp -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null /home/azureuser/instance_scripts/add-secondary_vm.sh ubuntu@${INTERNAL_IP}:~/
    ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null ubuntu@${INTERNAL_IP} "sudo /home/ubuntu/add-secondary_vm.sh"

    touch "$AZURE_USER_HOME/.net_setup_done"
fi

# ── Step 5: Install k0s inside the QEMU VM ───────────────────────────────────
if [ -f "$AZURE_USER_HOME/.net_setup_done" ] && [ ! -f "$AZURE_USER_HOME/.k0s_in_vm_done" ]; then
    step_log "Step 5: Installing k0s inside the VM" ""

    sudo apt-get install -y sshpass

    if [ "${INSTANCE_ID}" -eq "0" ]; then
        step_log "INSTANCE 0: copying master_install_k0.sh to ${INTERNAL_IP}"
        scp -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null /home/azureuser/instance_scripts/master_install_k0.sh ubuntu@${INTERNAL_IP}:/tmp/
    else
        step_log "INSTANCE ${INSTANCE_ID}: copying worker_install_k0.sh to ${INTERNAL_IP}"
        scp -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null /home/azureuser/instance_scripts/worker_install_k0.sh ubuntu@${INTERNAL_IP}:/tmp/
    fi

    scp -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null /home/azureuser/instance_scripts/common_k0.sh ubuntu@${INTERNAL_IP}:/tmp/

    step_log "Creating SSH keys on QEMU VM"
    ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null ubuntu@${INTERNAL_IP} "mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -q -t rsa -N \"\" -f ~/.ssh/id_rsa"

    if [ "${INSTANCE_ID}" -eq "0" ]; then
        step_log "Running master_install_k0.sh on ${INTERNAL_IP}"
        ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null ubuntu@${INTERNAL_IP} "bash /tmp/master_install_k0.sh"
    else
        step_log "Running worker_install_k0.sh on ${INTERNAL_IP} with controller=10.2.0.7"
        ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null ubuntu@${INTERNAL_IP} "bash /tmp/worker_install_k0.sh 10.2.0.7"
    fi

    sudo gcc -pthread /home/azureuser/instance_scripts/slotcheckerservice.c -o slotcheckerservice
    sudo cp /home/azureuser/instance_scripts/slotcheckerservice.service /etc/systemd/system/slotcheckerservice.service
    sudo systemctl daemon-reload
    sudo systemctl enable slotcheckerservice
    sudo systemctl start slotcheckerservice

    touch "$AZURE_USER_HOME/.k0s_in_vm_done"
fi

step_log "Step 6: DRY RUN COMPLETE"
echo ""
echo "=== Full command log written to: $DRY_RUN_LOG ==="
