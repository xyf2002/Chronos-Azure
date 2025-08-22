#!/bin/bash
# Usage: remote_build_kernel.sh INSTANCE_ID INSTANCE_COUNT GITHUB_USERNAME GITHUB_TOKEN
INSTANCE_ID="$1"
MACHINE_NUM="$2"
GITHUB_USERNAME="$3"
GITHUB_TOKEN="$4"

# Use $HOME for logging
exec > >(tee -a "$HOME/build.log") 2>&1
echo "Log file stored at: $HOME/build.log"

# ======= Network Setup Variables =======
INTERNAL_SUBNET=$((INSTANCE_ID))
INTERNAL_IP="10.2.${INTERNAL_SUBNET}.6"
NET_GW_IP="10.2.${INTERNAL_SUBNET}.1"
RANGE_START="10.2.${INTERNAL_SUBNET}.2"
RANGE_END="10.2.${INTERNAL_SUBNET}.254"
EXPOSED_IP="10.1.${INSTANCE_ID}.1"
echo "Instance_ID: ${INSTANCE_ID}, MACHINE_NUM: ${MACHINE_NUM}"
echo "Internal Subnet: 10.2.${INTERNAL_SUBNET}.0/24, Internal IP: ${INTERNAL_IP}"

# ======= Integrated build_kernel script begins =======
# Define step_log function with clear separators
step_log() {
    echo ""
    echo "====== $1 ======"
    date
    [ -n "$2" ] && echo "$2"
    echo ""
}

# Step 0: Initialization
step_log "Step 0: Initialization" "Starting integrated build_kernel process"
touch "$HOME/.kernel_done" "$HOME/.rebooted"

# Step 1: Kernel Build logic commented out
step_log "Step 1: Kernel Build, already done"
# : <<'END_KERNEL_BUILD'
# ...existing kernel build commands...
# END_KERNEL_BUILD
touch "$HOME/.kernel_done"
touch "$HOME/.rebooted"

################################################################################
# Step 2: After Reboot, build & insert fake_tsc
################################################################################
if [ -f "$HOME/.kernel_done" ] && [ -f "$HOME/.rebooted" ] && [ ! -f "$HOME/.tsc_done" ]; then
    step_log "Step 2: After reboot - Build and insert fake_tsc module" ""
    rm -f "$HOME/.rebooted"
    cd "$HOME"
    # If build tools (gcc & make) not found, install them
    if ! command -v gcc >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1; then
        step_log "Installing build-essential package" "Installing required build tools..."
        wait_for_lock() {
            while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
                echo "Waiting for dpkg lock to be released..."
                sleep 5
            done
        }
        wait_for_lock
        sudo -S apt-get update -y
        sudo -S apt-get install -y build-essential
    fi

    if [ ! -d fake_tsc ]; then
        git clone "https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/ujjwalpawar/fake_tsc.git"
    fi
    cd fake_tsc
    [ -f init.c ] && { step_log "Compiling init.c" ""; gcc init.c -o init; }
    [ -f shared.c ] && { step_log "Compiling shared.c" ""; gcc shared.c -o shared; }

    step_log "Building fake_tsc module" ""; sudo make -C /lib/modules/$(uname -r)/build M=$PWD modules
    step_log "Inserting custom_tsc.ko" ""; sudo insmod custom_tsc.ko; sudo modprobe kvm; sudo modprobe kvm_intel; sudo ./init; sudo ./init
    step_log "Installing additional libs and verifying fake_tsc module" ""; sudo apt-get install -yqq libsctp-dev lksctp-tools zlib1g-dev; sudo modprobe sctp; sudo lsmod | grep custom_tsc || echo 'Warning: custom_tsc not loaded'; sudo dmesg | tail -n 20
    cp ~/scripts/slotcheckerservice.c ./; gcc slotcheckerservice.c -o slotcheckerservice
    touch "$HOME/.tsc_done"
fi

# Step 3: VM Setup
step_log "Step 3: VM Setup"
################################################################################
# Step 3: VM setup — uvt-kvm create ► virsh set MAC ► 固定 IP (DHCP host 条目)
################################################################################
# Preconditions
#   – $HOME/.tsc_done exists
#   – $HOME/.vm_setup_done NOT exists
################################################################################
if [ -f "$HOME/.tsc_done" ] && [ ! -f "$HOME/.vm_setup_done" ]; then
    step_log "Installing virtualization tools and creating VM (uvt-kvm + static MAC)"

    # 1. Packages
    sudo apt-get update
    sudo apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients \
                            bridge-utils virtinst uvtool iptables

    # 2. Sync cloud image (once per host)
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

    # Restart libvirtd service to apply changes
    sudo systemctl restart libvirtd
    sleep 5

    # Ensure libvirt network rules are set up
    sudo iptables -t filter -N LIBVIRT_INP 2>/dev/null || true
    sudo iptables -t filter -N LIBVIRT_OUT 2>/dev/null || true
    sudo iptables -t filter -N LIBVIRT_FWO 2>/dev/null || true
    sudo iptables -t filter -N LIBVIRT_FWI 2>/dev/null || true
    sudo iptables -t filter -N LIBVIRT_FWX 2>/dev/null || true


    if ! sudo virsh net-info default >/dev/null 2>&1; then
        sudo virsh net-define /usr/share/libvirt/networks/default.xml
    fi
    sudo virsh net-start default || echo "Network already started"

    # 3. Names & deterministic IP/MAC
    VM_NAME="ins${INSTANCE_ID}"

    #step_log "Changing default storage location"
   # sudo $HOME/repository/scripts/change_storage.sh

    step_log "VM  = ${VM_NAME}"
    step_log "Int = ${INTERNAL_IP}"

    # 4. Create VM
    if ! sudo uvt-kvm create "${VM_NAME}" \
            release=focal arch=amd64 \
            --cpu 2 --memory 4096 --password 1997; then
        echo "❌ uvt-kvm create failed, aborting"; exit 1
    fi

     step_log "Modifying /etc/libvirt/qemu/$VM_NAME.xml to patch CPU and clock settings"
            VM_XML="/etc/libvirt/qemu/${VM_NAME}.xml"
            TMP_XML="/tmp/${VM_NAME}.xml.modified"

            sudo cp "$VM_XML" "$VM_XML.bak"

            step_log "Deleting two lines after </features>"
            sudo awk '
            /<\/features>/ {
                print;
                skip = 2;
                next;
            }
            skip > 0 {
                skip--;
                next;
            }
            { print }
            ' "$VM_XML" > "$TMP_XML"

            step_log "Inserting new <cpu> and <clock> blocks"
            sudo sed -i "/<\/features>/a \
        <cpu mode='host-passthrough' check='none'>\\
          <feature policy='disable' name='rdtscp'/>\\
          <feature policy='disable' name='tsc-deadline'/>\\
        </cpu>\\
        <clock offset='localtime'>\\
          <timer name='rtc' present='no' tickpolicy='delay'/>\\
          <timer name='pit' present='no' tickpolicy='discard'/>\\
          <timer name='hpet' present='no'/>\\
          <timer name='kvmclock' present='yes'/>\\
        </clock>" "$TMP_XML"

            step_log "Replacing $VM_NAME.xml with modified version and redefining domain"
            sudo mv "$TMP_XML" "$VM_XML"
            sudo virsh define "$VM_XML"

            sudo virsh destroy "$VM_NAME"
            sudo virsh start "$VM_NAME"


    # --------------------------------------------------------------------- #
        # 3. Waiting domifaddr return real MAC/IP
        # --------------------------------------------------------------------- #
        step_log "Waiting domifaddr for ${VM_NAME}"
        for i in {1..30}; do
            domif=$(sudo virsh domifaddr "$VM_NAME" 2>&1)
            if echo "$domif" | grep -q 'ipv4'; then
                break
            fi
            sleep 2
        done
        step_log "domifaddr output" "$domif"

    REAL_MAC=$(echo "$domif" | awk '/ipv4/ {print $2}')

    if [ -z "$REAL_MAC" ] ; then
            echo "❌ domifaddr did not return MAC, aborting"; exit 1
        fi


################################################################################
# Step 3.5   virsh set MAC ► static IP (DHCP host )
################################################################################
################################################################################

    step_log "Edit the default network"
    NET_XML="/etc/libvirt/qemu/networks/default.xml"

    if ! sudo grep -q "$REAL_MAC" "$NET_XML"; then
      step_log "Adding DHCP host entry for ${VM_NAME} in default network : ${NET_GW_IP}"
      sudo sed -i -E "
        # -- bridge / gateway ----------------------------------------------------
        0,/<ip address=/{
            s@<ip address='[0-9.]+' netmask='255\.255\.255\.0'>@<ip address='${NET_GW_IP}' netmask='255.255.255.0'>@
        }

        # -- DHCP range ----------------------------------------------------------
        /<range /{
            s@start='[0-9.]+'@start='${RANGE_START}'@
            s@end='[0-9.]+'@end='${RANGE_END}'@
        }

        # -- purge any old host entry for this VM --------------------------------
        /<dhcp>/,/<\/dhcp>/{
            /<host .*name='${VM_NAME}'.*\/>/d
        }

        # -- add fresh host reservation -----------------------------------------
        /<range /a\\
            <host mac='${REAL_MAC}' name='${VM_NAME}' ip='${INTERNAL_IP}'/>
        "  "$NET_XML"

    fi
    step_log "stopping ${VM_NAME} to change ip address"
    sudo virsh shutdown "${VM_NAME}"

    # Fix the loop bounds and output messages
    for i in $(seq 1 20); do
        state=$(sudo virsh domstate "${VM_NAME}" 2>/dev/null) || state="unknown"
        echo "⏳ Waiting for ${VM_NAME} to shut off... (${i}/20) → state: ${state}"
        [[ "$state" == "shut off" ]] && break
        [[ "$state" == "unknown" ]] && break

        # Retry shutdown command every few attempts
        if [[ $((i % 5)) -eq 0 ]]; then
            sudo virsh shutdown "${VM_NAME}" 2>/dev/null || true
        fi
        sleep 2
    done

    if [[ "$state" != "shut off" && "$state" != "unknown" ]]; then
        echo "⚠️  ${VM_NAME} did not shut off in time; forcing shutdown"
        sudo virsh destroy "${VM_NAME}"
        sleep 2
    fi
    step_log "Restarting libvirt default network"
    sudo virsh net-destroy default

    step_log "Restarting libvirtd service to apply changes"
    sudo service libvirtd restart

    sudo systemctl restart libvirtd

    sudo virsh net-start  default
    sleep 10
    # 8. start VM


    step_log "Starting ${VM_NAME} again"
    sudo virsh start "${VM_NAME}"

    # Fix the loop bounds and output messages for starting
    for i in $(seq 1 60); do
        state=$(sudo virsh domstate "${VM_NAME}" 2>/dev/null) || state="unknown"
        echo "⏳ Waiting for ${VM_NAME} to start... (${i}/60) → state: ${state}"
        [[ "$state" == "running" ]] && break
        sleep 2
    done

    if [[ "$state" != "running" ]]; then
        echo "❌ ${VM_NAME} failed to start within 2 minutes"
        exit 1
    fi

    sleep 30
    domif_output2=$(sudo virsh domifaddr "${VM_NAME}" 2>&1)
    step_log "Assigned IP address from domifaddr for ${VM_NAME}" "${domif_output2}"

    # 9. Wait until DHCP assigns the fixed IP
    step_log "Waiting for ${VM_NAME} to get IP ${INTERNAL_IP}"
    for i in {1..30}; do
        ip_list=$(sudo virsh domifaddr "${VM_NAME}" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1)
        for ip in $ip_list; do
            if [[ "$ip" == "$INTERNAL_IP" ]]; then
                cur_ip="$ip"
                break 2  # Exit both loops
            fi
        done
        sleep 2
    done
    [[ "${cur_ip}" != "${INTERNAL_IP}" ]] && echo "⚠️  VM IP is ${cur_ip:-N/A}, expected ${INTERNAL_IP}"
    touch "$HOME/.vm_setup_done"
fi

################################################################################
# Step 4: Exposed-IP alias  &  NAT rules
################################################################################
# Preconditions
#   – $HOME/.vm_setup_done   exists  (VM created)
#   – $HOME/.net_setup_done  NOT     exists (NAT not yet written)
################################################################################
if [ -f "$HOME/.vm_setup_done" ] && [ ! -f "$HOME/.net_setup_done" ]; then
    step_log "Setting alias IP and NAT rules for this host"
    state=$(sudo virsh domstate "${VM_NAME}" 2>/dev/null) || true
    echo "⏳ Checking state of ${VM_NAME} to shut off... (${i}/20) -> state: ${state}"
    [[ "$state" == "shut off" ]] && sudo virsh start ${VM_NAME}
    for i in {1..200}; do
        state=$(sudo virsh domstate "${VM_NAME}" 2>/dev/null) || true
        echo "⏳ Waiting for ${VM_NAME} to start... (${i}/20) → state: ${state}"
        [[ "$state" == "running" ]] && break
        sleep 1
    done
    cd ~/scripts
    step_log "Adding ips"
    sudo ~/scripts/add-secondary.sh
    sleep 5
    step_log "Generating json"
    sudo ~/scripts/generate_config.sh $MACHINE_NUM
    sleep 5
    step_log "Adding IP TABLES"
    sudo ~/scripts/set_ip.sh
    sleep 5
    step_log "Installing ssh pass"
    sudo apt-get -y install sshpass
    password="1997"
    SSH_OPTS="-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
    step_log "create ssh keys"
    ssh-keygen -q -t rsa -N '' -f ~/.ssh/id_rsa
    step_log "Copying ssh keys"
    sshpass -p $password ssh-copy-id $SSH_OPTS ubuntu@${INTERNAL_IP}

    step_log "Copying script to add ip address"
    scp $SSH_OPTS ~/scripts/add-secondary_vm.sh ubuntu@${INTERNAL_IP}:~/
    step_log "calling copied script"
    ssh $SSH_OPTS ubuntu@${INTERNAL_IP}  "sudo /home/ubuntu/add-secondary_vm.sh"
    touch $HOME/.net_setup_done
fi

################################################################################
# Step 5: Install k0s inside the VM
################################################################################
if [ -f "$HOME/.net_setup_done" ] && [ ! -f "$HOME/.k0s_in_vm_done" ]; then
    step_log "Step 5: Installing k0s inside the VM" ""
    if ! command -v sshpass >/dev/null 2>&1; then
        step_log "Installing sshpass" ""; sudo apt-get install -y sshpass
    fi

    if [ "${INSTANCE_ID}" -eq "0" ]; then
        step_log "Copying master k0s install script to VM" ""
        scp -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null ~/scripts/master_install_k0.sh ubuntu@${INTERNAL_IP}:/tmp/
    else
        step_log "Copying worker k0s install script to VM" ""
        scp -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null ~/scripts/worker_install_k0.sh ubuntu@${INTERNAL_IP}:/tmp/
    fi

    step_log "Copying common k0s helper script to VM" ""
    scp -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null ~/scripts/common_k0.sh ubuntu@${INTERNAL_IP}:/tmp/

    step_log "Creating SSH keys on VM" ""
    ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null ubuntu@${INTERNAL_IP} "mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -q -t rsa -N \"\" -f ~/.ssh/id_rsa"
    if [ "${INSTANCE_ID}" -eq "0" ]; then
        step_log "Running master k0s install script" ""
        ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null ubuntu@${INTERNAL_IP} "bash /tmp/master_install_k0.sh"
    else
        ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null ubuntu@${INTERNAL_IP} "bash /tmp/worker_install_k0.sh 10.2.0.1"
    fi
    sudo gcc -pthread ~/scripts/slotcheckerservice.c -o slotcheckerservice
    sudo cp ~/scripts/slotcheckerservice.service /etc/systemd/system/slotcheckerservice.service
    sudo systemctl daemon-reload; sudo systemctl enable slotcheckerservice; sudo systemctl start slotcheckerservice
    touch "$HOME/.k0s_in_vm_done"
fi

# Step 6: All done
step_log "Step 6: Completed" "All steps already completed."
