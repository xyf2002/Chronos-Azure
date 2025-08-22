#!/bin/bash

# Script to fix networking issues in nested virtualization on Azure

echo "Fixing nested virtualization networking on Azure VM..."

# Get primary interface
PRIMARY_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
echo "Primary interface: ${PRIMARY_IFACE}"

# 1. Enable IP forwarding and bridge settings
echo "Enabling IP forwarding and bridge settings..."
echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward

if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
    sudo tee -a /etc/sysctl.conf > /dev/null <<EOF
# Network settings for nested virtualization
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.proxy_arp = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.netfilter.nf_conntrack_max = 131072
EOF
fi
sudo sysctl -p

# 2. Load required kernel modules
echo "Loading required kernel modules..."
sudo modprobe br_netfilter
sudo modprobe ip_tables
sudo modprobe iptable_nat
sudo modprobe ip_conntrack

# 3. Configure comprehensive iptables rules
echo "Configuring iptables for nested VMs..."
sudo iptables -F
sudo iptables -t nat -F
sudo iptables -t mangle -F

# Set default policies
sudo iptables -P INPUT ACCEPT
sudo iptables -P FORWARD ACCEPT
sudo iptables -P OUTPUT ACCEPT

# Allow loopback
sudo iptables -A INPUT -i lo -j ACCEPT

# Allow established connections
sudo iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
sudo iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# Critical: Allow forwarding between different 192.168.x.x subnets
sudo iptables -A FORWARD -s 192.168.0.0/16 -d 192.168.0.0/16 -j ACCEPT
sudo iptables -A FORWARD -s 10.0.0.0/8 -d 192.168.0.0/16 -j ACCEPT
sudo iptables -A FORWARD -s 192.168.0.0/16 -d 10.0.0.0/8 -j ACCEPT

# Allow all traffic on libvirt bridges
sudo iptables -A INPUT -i virbr+ -j ACCEPT
sudo iptables -A FORWARD -i virbr+ -j ACCEPT
sudo iptables -A FORWARD -o virbr+ -j ACCEPT

# Internet access for VMs
sudo iptables -A FORWARD -i virbr0 -o ${PRIMARY_IFACE} -j ACCEPT
sudo iptables -A FORWARD -i ${PRIMARY_IFACE} -o virbr0 -m state --state RELATED,ESTABLISHED -j ACCEPT

# NAT for internet access
sudo iptables -t nat -A POSTROUTING -o ${PRIMARY_IFACE} -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -s 192.168.0.0/16 ! -d 192.168.0.0/16 -j MASQUERADE

# DNS and ICMP
sudo iptables -A FORWARD -p udp --dport 53 -j ACCEPT
sudo iptables -A FORWARD -p tcp --dport 53 -j ACCEPT
sudo iptables -A INPUT -p udp --dport 53 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 53 -j ACCEPT
sudo iptables -A FORWARD -p icmp -j ACCEPT
sudo iptables -A INPUT -p icmp -j ACCEPT

# 4. Install and configure dnsmasq
echo "Installing and configuring dnsmasq..."
sudo apt-get update -qq
sudo apt-get install -y dnsmasq bind9-utils bridge-utils

# Stop conflicting services
sudo systemctl stop systemd-resolved 2>/dev/null || true

# Configure dnsmasq
sudo tee /etc/dnsmasq.d/libvirt.conf > /dev/null <<EOF
# Enhanced DNS configuration for libvirt VMs
interface=virbr0
bind-interfaces
domain-needed
bogus-priv
expand-hosts
local=/localdomain/

# Multiple DNS servers for redundancy
server=8.8.8.8
server=8.8.4.4
server=1.1.1.1
server=208.67.222.222

# Listen on libvirt bridge and localhost
listen-address=127.0.0.1

# Cache configuration
cache-size=1000
neg-ttl=3600

# Enable logging for debugging
log-queries
log-dhcp
EOF

# Create main resolv.conf
sudo tee /etc/resolv.conf > /dev/null <<EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
search localdomain
EOF

sudo systemctl restart dnsmasq
sudo systemctl enable dnsmasq

# 5. Configure libvirt network
echo "Configuring libvirt network..."
if sudo virsh net-info default >/dev/null 2>&1; then
    sudo virsh net-destroy default 2>/dev/null || true
fi

# Create enhanced libvirt network XML
LIBVIRT_NET_XML="/tmp/enhanced-default.xml"
sudo tee ${LIBVIRT_NET_XML} > /dev/null <<EOF
<network>
  <name>default</name>
  <uuid>$(uuidgen)</uuid>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='virbr0' stp='on' delay='0'/>
  <mac address='52:54:00:12:34:56'/>
  <domain name='localdomain' localOnly='yes'/>
  <dns enable='yes'>
    <forwarder addr='8.8.8.8'/>
    <forwarder addr='8.8.4.4'/>
    <forwarder addr='1.1.1.1'/>
  </dns>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.2' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
EOF

sudo virsh net-define ${LIBVIRT_NET_XML}
sudo virsh net-start default
sudo virsh net-autostart default

# 6. Test connectivity
echo "Testing connectivity..."
echo "Testing ping to 8.8.8.8:"
ping -c 3 8.8.8.8 && echo "✓ Can reach 8.8.8.8" || echo "✗ Cannot reach 8.8.8.8"

echo "Testing DNS resolution:"
nslookup google.com && echo "✓ DNS resolution working" || echo "✗ DNS resolution failed"

# 7. Show current configuration
echo "Current network configuration:"
echo "IP forwarding: $(cat /proc/sys/net/ipv4/ip_forward)"
echo "Primary interface: ${PRIMARY_IFACE}"
echo "Libvirt network status:"
sudo virsh net-list --all
echo "Bridge status:"
ip addr show virbr0 2>/dev/null || echo "virbr0 not found"
echo "iptables NAT rules:"
sudo iptables -t nat -L -n | head -10

echo "✓ Nested virtualization networking configuration completed."
echo "You may need to restart VMs for changes to take effect."
