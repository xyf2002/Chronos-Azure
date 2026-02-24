#!/bin/bash
# Usage: build_instance.sh INSTANCE_ID INSTANCE_COUNT
INSTANCE_ID="$1"
MACHINE_NUM="$2"

# Define Azure user home directory
AZURE_USER_HOME="/home/azureuser"

# Use $AZURE_USER_HOME for logging
exec > >(tee -a "$AZURE_USER_HOME/build.log") 2>&1
echo "Log file stored at: $AZURE_USER_HOME/build.log"

# ======= Network Setup Variables =======
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

# Register a systemd service so this script re-runs automatically after each
# reboot until all steps are complete (kernel build requires a reboot mid-run).
SERVICE_FILE="/etc/systemd/system/build-instance.service"
if [ ! -f "$SERVICE_FILE" ]; then
    sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=Chronos instance build (reboot-persistent)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${AZURE_USER_HOME}/instance_scripts/build_instance.sh ${INSTANCE_ID} ${MACHINE_NUM}
RemainAfterExit=yes
StandardOutput=append:${AZURE_USER_HOME}/build.log
StandardError=append:${AZURE_USER_HOME}/build.log

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable build-instance.service
fi

################################################################################
# Step 1: Kernel Build
################################################################################
if [ ! -f "$AZURE_USER_HOME/.kernel_done" ]; then
    step_log "Step 1: Building Chronos kernel"

    wait_for_apt_lock() {
        while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
            echo "Waiting for dpkg lock to be released..."
            sleep 5
        done
    }
    wait_for_apt_lock
    sudo apt-get update -y
    sudo apt-get install -y build-essential flex bison libssl-dev libelf-dev dwarves zstd

    KERNEL_DIR="$AZURE_USER_HOME/chronos-kernel"
    if [ ! -d "$KERNEL_DIR" ]; then
        step_log "Cloning chronos-kernel"
        git clone --quiet "https://github.com/ujjwalpawar/chronos-kernel.git" "$KERNEL_DIR"
    fi

    cd "$KERNEL_DIR"
    cp "/boot/config-$(uname -r)" .config
    scripts/config --disable SYSTEM_TRUSTED_KEYS
    scripts/config --disable SYSTEM_REVOCATION_KEYS
    scripts/config --disable VIDEO_OV01A10
    scripts/config --enable NETFILTER_XTABLES
    scripts/config --enable NETFILTER_XT_MARK
    scripts/config --enable NETFILTER_XT_TARGET_MARK
    scripts/config --enable PREEMPT_RT_FULL
    scripts/config --disable DEBUG_INFO_BTF
    make olddefconfig
    make "-j$(nproc)"
    sudo make INSTALL_MOD_STRIP=1 modules_install
    sudo make install
    sudo sed -i 's/DEFAULT=0/DEFAULT="1>2"/g' /etc/default/grub.d/50-cloudimg-settings.cfg
    sudo update-grub

    ################################################################################
    # Step 1.5: Configure tuned for CPU isolation
    ################################################################################
    HOST_CPUS=$(nproc)
    step_log "Installing tuned and configuring CPU isolation (cores 2-$((HOST_CPUS - 1)))"
    sudo apt-get install -y tuned

    sudo ln -sf /boot/grub/grub.cfg /etc/grub2.cfg
    echo 'echo "export tuned_params"' | sudo tee -a /etc/grub.d/00_tuned

    echo "isolated_cores=2-$((HOST_CPUS - 1))" | sudo tee /etc/tuned/realtime-variables.conf

    sudo sed -i '/^cmdline_realtime=/d' /usr/lib/tuned/realtime/tuned.conf

    if ! grep -q "^\[bootloader\]" /usr/lib/tuned/realtime/tuned.conf; then
        echo -e "\n[bootloader]" | sudo tee -a /usr/lib/tuned/realtime/tuned.conf
    fi

    sudo sed -i '/^\[bootloader\]/a cmdline_realtime=+isolcpus=${managed_irq}${isolated_cores} nohz_full=${isolated_cores} rcu_nocbs=${isolated_cores} nosoftlockup' /usr/lib/tuned/realtime/tuned.conf

    sudo tuned-adm profile realtime

    touch "$AZURE_USER_HOME/.kernel_done"
    step_log "Kernel build complete, rebooting to load new kernel..."
    sudo reboot
    exit 0
else
    step_log "Step 1: Kernel build already done, skipping"
fi

################################################################################
# Step 2: After Reboot, build & insert fake_tsc
################################################################################
if [ -f "$AZURE_USER_HOME/.kernel_done" ] && [ ! -f "$AZURE_USER_HOME/.tsc_done" ]; then
    step_log "Step 2: After reboot - Build and insert fake_tsc module" ""
    cd "$AZURE_USER_HOME"
    # Install build tools and kernel headers (always needed for module build)
    wait_for_lock() {
        while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
            echo "Waiting for dpkg lock to be released..."
            sleep 5
        done
    }
    wait_for_lock
    sudo -S apt-get update -y
    sudo -S apt-get install -y build-essential linux-headers-$(uname -r)

    if [ ! -d fake_tsc ]; then
        git clone "https://github.com/ujjwalpawar/fake_tsc.git"
    fi
    cd fake_tsc
    [ -f init.c ] && { step_log "Compiling init.c" ""; gcc init.c -o init; }
    [ -f shared.c ] && { step_log "Compiling shared.c" ""; gcc shared.c -o shared; }

    step_log "Building fake_tsc module" ""; sudo make -C /lib/modules/$(uname -r)/build M=$PWD modules
    step_log "Inserting custom_tsc.ko" ""; sudo insmod custom_tsc.ko; sudo modprobe kvm; sudo modprobe kvm_intel; sudo ./init; sudo ./init
    step_log "Installing additional libs and verifying fake_tsc module" ""; sudo apt-get install -yqq libsctp-dev lksctp-tools zlib1g-dev; sudo modprobe sctp; sudo lsmod | grep custom_tsc || echo 'Warning: custom_tsc not loaded'; sudo dmesg | tail -n 20
    cp $AZURE_USER_HOME/instance_scripts/slotcheckerservice.c ./; gcc slotcheckerservice.c -o slotcheckerservice
    touch "$AZURE_USER_HOME/.tsc_done"
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
if [ -f "$AZURE_USER_HOME/.tsc_done" ] && [ ! -f "$AZURE_USER_HOME/.vm_setup_done" ]; then
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
        DEFAULT_NET_XML="/usr/share/libvirt/networks/default.xml"
        if [ ! -f "$DEFAULT_NET_XML" ]; then
            sudo mkdir -p "$(dirname $DEFAULT_NET_XML)"
            sudo tee "$DEFAULT_NET_XML" > /dev/null <<'NETXML'
<network>
  <name>default</name>
  <forward mode="nat"><nat><port start="1024" end="65535"/></nat></forward>
  <bridge name="virbr0" stp="on" delay="0"/>
  <ip address="192.168.122.1" netmask="255.255.255.0">
    <dhcp><range start="192.168.122.2" end="192.168.122.254"/></dhcp>
  </ip>
</network>
NETXML
        fi
        sudo virsh net-define "$DEFAULT_NET_XML"
    fi
    sudo virsh net-autostart default
    sudo virsh net-start default 2>/dev/null || echo "Network already started"


    #step_log "Changing default storage location"
   # sudo $AZURE_USER_HOME/repository/instance_scripts/change_storage.sh

    step_log "VM  = ${VM_NAME}"
    step_log "Int = ${INTERNAL_IP}"

    # 4. Check if VM already exists
    if sudo virsh dominfo "${VM_NAME}" >/dev/null 2>&1; then
        step_log "VM ${VM_NAME} already exists, skipping creation"
    else
        step_log "Creating new VM ${VM_NAME}"
        # 4. Create VM
        HOST_CPUS=$(nproc)
        VM_CPUS=$(( HOST_CPUS > 2 ? HOST_CPUS - 2 : 1 ))
        HOST_MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
        VM_MEM_MB=$(( HOST_MEM_MB > 4096 ? HOST_MEM_MB - 4096 : HOST_MEM_MB / 2 ))
        if ! sudo uvt-kvm create "${VM_NAME}" \
                release=focal arch=amd64 \
                --cpu "${VM_CPUS}" --memory "${VM_MEM_MB}" --password 1997; then
            echo "❌ uvt-kvm create failed, aborting"; exit 1
        fi

        step_log "Modifying /etc/libvirt/qemu/$VM_NAME.xml to patch CPU and clock settings"
        VM_XML="/etc/libvirt/qemu/${VM_NAME}.xml"
        TMP_XML="/tmp/${VM_NAME}.xml.modified"

        sudo cp "$VM_XML" "$VM_XML.bak"

        step_log "Replacing cpu/clock blocks with host-passthrough versions"
        sudo awk '
        BEGIN { in_cpu=0; in_clock=0 }
        /<cpu[^>]*\/>/ { next }
        /<cpu[ >]/ { in_cpu=1; next }
        in_cpu && /<\/cpu>/ { in_cpu=0; next }
        in_cpu { next }
        /<clock[^>]*\/>/ { next }
        /<clock[ >]/ { in_clock=1; next }
        in_clock && /<\/clock>/ { in_clock=0; next }
        in_clock { next }
        /<\/features>/ {
            print
            print "  <cpu mode=\"host-passthrough\" check=\"none\">"
            print "    <feature policy=\"disable\" name=\"rdtscp\"/>"
            print "    <feature policy=\"disable\" name=\"tsc-deadline\"/>"
            print "  </cpu>"
            print "  <clock offset=\"localtime\">"
            print "    <timer name=\"rtc\" present=\"no\" tickpolicy=\"delay\"/>"
            print "    <timer name=\"pit\" present=\"no\" tickpolicy=\"discard\"/>"
            print "    <timer name=\"hpet\" present=\"no\"/>"
            print "    <timer name=\"kvmclock\" present=\"yes\"/>"
            print "  </clock>"
            next
        }
        { print }
        ' "$VM_XML" > "$TMP_XML"

        step_log "Pinning CPUs"
        NUM_CPU=$(nproc)
        if [ "$NUM_CPU" -ge "4" ]; then
            VCPU_SEQVAR=$((VM_CPUS - 1))
            EMULATORPIN_CPUSET=$((NUM_CPU - 2))
            IOTHREADPIN_CPUSET=$((NUM_CPU - 1))
            CPU_PIN_BLOCK=$(
                printf "  <iothreads>1</iothreads>\n"
                printf "  <cputune>\n"
                for i in $(seq 0 $VCPU_SEQVAR); do
                    printf "    <vcpupin vcpu='%d' cpuset='%d'/>\n" "$i" "$((i+2))"
                done
                printf "    <emulatorpin cpuset='%d'/>\n" "$EMULATORPIN_CPUSET"
                printf "    <iothreadpin iothread='1' cpuset='%d'/>\n" "$IOTHREADPIN_CPUSET"
                printf "    <vcpusched vcpus='0' scheduler='fifo' priority='1'/>\n"
                printf "    <vcpusched vcpus='1-%d' scheduler='fifo' priority='1'/>\n" "$VCPU_SEQVAR"
                printf "    <emulatorsched scheduler='fifo' priority='1'/>\n"
                printf "    <iothreadsched iothreads='1' scheduler='fifo' priority='1'/>\n"
                printf "  </cputune>"
            )
            printf "%s" "$CPU_PIN_BLOCK" | sudo tee /tmp/cputune_block.xml > /dev/null
            sudo sed -i "/<vcpu/r /tmp/cputune_block.xml" "$TMP_XML"
            sudo rm -f /tmp/cputune_block.xml
        fi

        step_log "Replacing $VM_NAME.xml with modified version and redefining domain"
        sudo mv "$TMP_XML" "$VM_XML"
        sudo virsh define "$VM_XML"

        sudo virsh destroy "$VM_NAME"
        sudo virsh start "$VM_NAME"
    fi

#    # Ensure VM is running regardless of whether it was just created or already existed
#    VM_STATE=$(sudo virsh domstate "${VM_NAME}" 2>/dev/null || echo "shut off")
#    if [[ "$VM_STATE" != "running" ]]; then
#        step_log "Starting existing VM ${VM_NAME}"
#        sudo virsh start "${VM_NAME}" || true
#
#        # Wait for VM to start
#        for i in $(seq 1 60); do
#            state=$(sudo virsh domstate "${VM_NAME}" 2>/dev/null) || state="unknown"
#            echo "⏳ Waiting for ${VM_NAME} to start... (${i}/60) → state: ${state}"
#            [[ "$state" == "running" ]] && break
#            sleep 2
#        done
#    fi

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
    step_log "Restarting libvirt default network with fresh configuration"
    sudo virsh net-destroy default

    # Undefine the network to wipe ALL stale lease state from libvirt's internal storage
    # (libvirt uses --leasefile-ro + leaseshelper, so sed on a lease file has no effect)
    sudo virsh net-undefine default

    # Redefine with a fresh XML containing only the current MAC reservation
    NETWORK_XML="/tmp/libvirt-default-net.xml"
    printf '<network>\n  <name>default</name>\n  <forward mode="nat"><nat><port start="1024" end="65535"/></nat></forward>\n  <bridge name="virbr0" stp="on" delay="0"/>\n  <ip address="%s" netmask="255.255.255.0">\n    <dhcp>\n      <range start="%s" end="%s"/>\n      <host mac="%s" name="%s" ip="%s"/>\n    </dhcp>\n  </ip>\n</network>\n' \
        "${NET_GW_IP}" "${RANGE_START}" "${RANGE_END}" "${REAL_MAC}" "${VM_NAME}" "${INTERNAL_IP}" \
        | sudo tee "${NETWORK_XML}" > /dev/null
    sudo virsh net-define "${NETWORK_XML}"
    sudo virsh net-autostart default
    sudo virsh net-start default
    sleep 5

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
    touch "$AZURE_USER_HOME/.vm_setup_done"
fi

################################################################################
# Step 4: Exposed-IP alias  &  NAT rules
################################################################################
# Preconditions
#   – $HOME/.vm_setup_done   exists  (VM created)
#   – $HOME/.net_setup_done  NOT     exists (NAT not yet written)
################################################################################
if [ -f "$AZURE_USER_HOME/.vm_setup_done" ] && [ ! -f "$AZURE_USER_HOME/.net_setup_done" ]; then
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
    cd $AZURE_USER_HOME/instance_scripts
    step_log "Adding ips"
    sudo $AZURE_USER_HOME/instance_scripts/add-secondary.sh
    sleep 5
    step_log "Generating json"
    sudo $AZURE_USER_HOME/instance_scripts/generate_config.sh $MACHINE_NUM
    sleep 5
    step_log "Adding IP TABLES"
    sudo $AZURE_USER_HOME/instance_scripts/set_ip.sh
    sleep 5
    step_log "Installing ssh pass"
    sudo apt-get -y install sshpass
    password="1997"
    SSH_KEY_DIR="$AZURE_USER_HOME/.ssh"
    SSH_PRIVATE_KEY="$SSH_KEY_DIR/id_rsa"
    SSH_PUBLIC_KEY="$SSH_PRIVATE_KEY.pub"
    SSH_OPTS="-i $SSH_PRIVATE_KEY -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
    step_log "create ssh keys"
    mkdir -p "$SSH_KEY_DIR"
    chmod 700 "$SSH_KEY_DIR"
    # Fix ownership if keys were previously created as root
    sudo chown "$(id -un):$(id -gn)" "$SSH_PRIVATE_KEY" "$SSH_PUBLIC_KEY" 2>/dev/null || true
    if [ -f "$SSH_PRIVATE_KEY" ] && [ ! -f "$SSH_PUBLIC_KEY" ]; then
        ssh-keygen -y -f "$SSH_PRIVATE_KEY" > "$SSH_PUBLIC_KEY"
    elif [ ! -f "$SSH_PRIVATE_KEY" ] || [ ! -f "$SSH_PUBLIC_KEY" ]; then
        ssh-keygen -q -t rsa -N '' -f "$SSH_PRIVATE_KEY"
    fi
    chmod 600 "$SSH_PRIVATE_KEY"
    chmod 644 "$SSH_PUBLIC_KEY"
    step_log "Copying ssh keys"
    sshpass -p "$password" ssh-copy-id -i "$SSH_PUBLIC_KEY" $SSH_OPTS ubuntu@${INTERNAL_IP}

    step_log "Copying script to add ip address"
    scp $SSH_OPTS $AZURE_USER_HOME/instance_scripts/add-secondary_vm.sh ubuntu@${INTERNAL_IP}:~/
    step_log "calling copied script"
    ssh $SSH_OPTS ubuntu@${INTERNAL_IP}  "sudo /home/ubuntu/add-secondary_vm.sh"
    touch $AZURE_USER_HOME/.net_setup_done
fi

################################################################################
# Step 5: Install k0s inside the VM
################################################################################
if [ -f "$AZURE_USER_HOME/.net_setup_done" ] && [ ! -f "$AZURE_USER_HOME/.k0s_in_vm_done" ]; then
    step_log "Step 5: Installing k0s inside the VM" ""
    if ! command -v sshpass >/dev/null 2>&1; then
        step_log "Installing sshpass" ""; sudo apt-get install -y sshpass
    fi

    # Enable cgroup v2 in the VM (k0s v1.31+ requires cgroup v2; Ubuntu 20.04 defaults to v1)
    step_log "Checking cgroup version in ${VM_NAME}"
    if ! ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null \
            ubuntu@${INTERNAL_IP} "grep -q 'unified_cgroup_hierarchy=1' /proc/cmdline" 2>/dev/null; then
        step_log "cgroup v2 not active — modifying GRUB and rebooting ${VM_NAME}"
        ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null ubuntu@${INTERNAL_IP} \
            'sudo sed -i "s/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX=\"systemd.unified_cgroup_hierarchy=1\"/" /etc/default/grub && sudo update-grub'
        ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null ubuntu@${INTERNAL_IP} \
            'sudo reboot' || true
        sleep 15
        step_log "Waiting for ${VM_NAME} to come back up after cgroup v2 reboot"
        for i in {1..60}; do
            if ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null \
                    -oConnectTimeout=5 ubuntu@${INTERNAL_IP} "echo ok" 2>/dev/null; then
                step_log "${VM_NAME} is back up"
                break
            fi
            echo "Waiting for VM to reboot... ($i/60)"
            sleep 5
        done
    else
        step_log "cgroup v2 already active in ${VM_NAME} — no reboot needed"
    fi

    if [ "${INSTANCE_ID}" -eq "0" ]; then
        step_log "Copying master k0s install script to VM" ""
        scp -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null $AZURE_USER_HOME/instance_scripts/master_install_k0.sh ubuntu@${INTERNAL_IP}:/tmp/
    else
        step_log "Copying worker k0s install script to VM" ""
        scp -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null $AZURE_USER_HOME/instance_scripts/worker_install_k0.sh ubuntu@${INTERNAL_IP}:/tmp/
    fi

    step_log "Copying common k0s helper script to VM" ""
    scp -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null $AZURE_USER_HOME/instance_scripts/common_k0.sh ubuntu@${INTERNAL_IP}:/tmp/

    step_log "Creating SSH keys on VM" ""
    ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null ubuntu@${INTERNAL_IP} "mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -q -t rsa -N \"\" -f ~/.ssh/id_rsa"
    if [ "${INSTANCE_ID}" -eq "0" ]; then
        step_log "Running master k0s install script" ""
        ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null ubuntu@${INTERNAL_IP} "bash /tmp/master_install_k0.sh"
    else
        ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null ubuntu@${INTERNAL_IP} "bash /tmp/worker_install_k0.sh 10.2.0.7"
    fi
    sudo gcc -pthread $AZURE_USER_HOME/instance_scripts/slotcheckerservice.c -o slotcheckerservice
    sudo cp $AZURE_USER_HOME/instance_scripts/slotcheckerservice.service /etc/systemd/system/slotcheckerservice.service
    sudo systemctl daemon-reload; sudo systemctl enable slotcheckerservice; sudo systemctl start slotcheckerservice
    touch "$AZURE_USER_HOME/.k0s_in_vm_done"
fi

################################################################################
# Step 6: Clone quick_deployment_tools and set up kubectl aliases (controller only)
################################################################################
if [ -f "$AZURE_USER_HOME/.k0s_in_vm_done" ] && [ ! -f "$AZURE_USER_HOME/.auto_deploy_setup" ] && [ "$INSTANCE_ID" -eq "0" ]; then
    step_log "Step 6: Cloning quick_deployment_tools and setting up aliases"
    SSH_OPTS="-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"

    step_log "Cloning quick_deployment_tools"
    ssh $SSH_OPTS ubuntu@"${INTERNAL_IP}" "git clone --quiet https://github.com/netsys-edinburgh/quick_deployment_tools.git ~/quick_deployment_tools"

    step_log "Installing parallel"
    sudo apt install -y parallel

    step_log "Appending aliases to .bashrc"
    ssh $SSH_OPTS ubuntu@"${INTERNAL_IP}" 'cat << '"'"'EOF'"'"' >> $HOME/.bashrc
s() {
  helm install --values values.yaml $1 ./$1/
}

ns() {
  helm uninstall $1
}

alias k="kubectl"
alias l="kubectl logs"
alias p="kubectl get pods"
alias pw="kubectl get pods -o wide"
EOF'
    touch "$AZURE_USER_HOME/.auto_deploy_setup"
fi

step_log "All steps completed."
