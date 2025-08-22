#!/bin/bash
# Builds the kernel from source, installs it, and also builds the custom
# Chronos kernel module for the same version. Finally, creates two QEMU VMs
# and configures them for Chronos.

# Color (disable if not a TTY)
GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color
if ! test -t 1; then
    GREEN=""
    BLUE=""
    NC=""
fi

################################################################################
#
# Utility functions
#
################################################################################

function success() {
    printf "${GREEN}$1${NC}\n" "${@:2}"
}

function info() {
    printf "${BLUE}$1${NC}\n" "${@:2}"
}

################################################################################
#
# Input Validation
#
################################################################################

# Ensure this script has only been run once
if [ -f ~/base_image_ready ]; then
    success "Already ran this script. Exiting."
    exit 0
fi

################################################################################
#
# Kernel Build
#
################################################################################

# apt-get update fails unless we do this
info "Fixing apt-get update"
sudo apt-get update

sudo apt-get install -y --reinstall libappstream* --fix-missing

info "Installing kernel build dependencies"

# Essentials for building the kernel
sudo apt-get install -y build-essential flex bison libssl-dev libelf-dev dwarves --fix-missing
# Nice to have utilities
sudo apt-get install -y ripgrep --fix-missing

if [ ! -d /home/root/chronos-kernel ]; then
    info "chronos-kernel directory not found, aborting."
    exit 1
fi

cd /home/root/chronos-kernel || exit

info "Copying current kernel config to .config"
cp "/boot/config-$(uname -r)" .config # Copy the current kernel config

info "Disabling or enabling problematic kernel modules"
# Disable key-related options since they error out if not provided
scripts/config --disable SYSTEM_TRUSTED_KEYS
scripts/config --disable SYSTEM_REVOCATION_KEYS
# Disable this one particular camera driver since it errors
scripts/config --disable VIDEO_OV01A10
# Enable netfilter for VM networking with iptables
scripts/config --enable NETFILTER_XTABLES
scripts/config --enable NETFILTER_XT_MARK
scripts/config --enable NETFILTER_XT_TARGET_MARK
scripts/config --enable PREEMPT_RT_FULL
scripts/config --disable DEBUG_INFO_BTF

# Run olddefconfig after disabling/enabling options since otherwise our
# manual changes might overwrite the "don't prompt, use default" behaviour
info "Running olddefconfig"
make olddefconfig # Equivalent to oldconfig but doesn't prompt for new options

# Build the kernel
info "Building the kernel"
make "-j$(nproc)"
info "Installing the kernel"
sudo make INSTALL_MOD_STRIP=1 modules_install
sudo make install

# Set the default kernel to the new one for the next boot
info "Setting the new kernel as the default"
sudo sed -i 's/DEFAULT=0/DEFAULT="1>2"/g' /etc/default/grub.d/50-cloudimg-settings.cfg
sudo update-grub

################################################################################
#
# Extras
#
################################################################################

# Now, we set up the virtualization environments
info "Setting up components needed for virtualization"
# Use legacy iptables otherwise we error with starting the libvirt default network
sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

# Tool for simplifying the creation of Ubuntu VMs
sudo apt-get install -y uvtool

# Required by https://cloud.google.com/compute/docs/instances/nested-virtualization/creating-nested-vms
sudo apt-get install -y uml-utilities qemu-kvm bridge-utils virtinst libvirt-daemon-system libvirt-clients

# Pull image tags
sudo uvt-simplestreams-libvirt sync --source https://cloud-images.ubuntu.com/daily/ release=jammy arch=amd64

# Auto-start the default network on next boot
sudo virsh net-autostart default

# Set sshd to allow MaxStartups up to 1000 connections since otherwise SSH tests
# can sporadically fail due to too many connections
sudo sed -i 's/#MaxStartups 10:30:100/MaxStartups 1000/' /etc/ssh/sshd_config && sudo sed -i 's/#MaxSessions 10/MaxSessions 1000/' /etc/ssh/sshd_config && sudo systemctl restart sshd

# Set up iptables-persistent to save our iptables rules across reboots
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
sudo apt-get -y install iptables-persistent

# Some miscellaneous setup
# Disable some unneeded MOTD messages
sudo chmod -x /etc/update-motd.d/10-help-text
sudo chmod -x /etc/update-motd.d/50-motd-news
sudo chmod -x /etc/update-motd.d/50-landscape-sysinfo
sudo chmod -x /etc/update-motd.d/90-updates-available
sudo chmod -x /etc/update-motd.d/91-contract-ua-esm-status
sudo chmod -x /etc/update-motd.d/91-release-upgrade
mkdir -p ~/.ssh
BLUE="\033[34m"
RESET="\033[0m"
cat <<ASD >> ~/.ssh/rc
test -z \$SSH_TTY && return # Don't run when not-interactive like SCP
echo "${BLUE}This is a RANvisor host instance. The following VMs are active:"
export LIBVIRT_DEFAULT_URI=qemu:///system
echo "\$(virsh list --name | sed -e '/^\$/d' -e 's/^/ - /g')"
echo "You can reach them via SSH <hostname> or through uvt-kvm ssh.${RESET}"
ASD

touch ~/.base_image_ready

success "Complete! Ready to reboot (will happen automatically)."