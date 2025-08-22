# Chronos Azure

Deploy Chronos on Azure. This automation covers:

- [x] Compiling the Chronos kernel module and modified KVM module
- [x] Creating a configurable number of Chronos instances (Azure VMs)
- [x] Launching a configurable number of time-dilated VMs within each Azure VM
- [x] Setting up mesh network routing between all instances and VMs
    - Every instance and VM can ping and SSH each other by IP and hostname
    - VM <-> VM communication uses Azure VNet and subnet features
- [x] Forming a Kubernetes cluster with time-dilated VMs

---

## 1. Create the Base Image

This script creates a development VM in Azure, clones, builds, and installs the KVM-modified kernel, and saves it as a boot image in the Azure Shared Image Gallery. The VM is then deleted.

**Example usage:**
```bash
./create_image_Azure.sh <project-id> \
  --resource-group=<resource-group> \
  --machine-type=<machine-type> \
  --disk-size=<disk-size(GB)> \
  --zone=<zone>
```
**Parameter description:**
- `<project-id>`: Azure project ID (required)
- `--resource-group`: Azure resource group name (required)
- `--machine-type`: Azure VM type, e.g., `Standard_D4s_v4` (optional, see script default)
- `--disk-size`: System disk size in GB (optional, see script default)
- `--zone`: Azure region, e.g., `uksouth` (required)

**Full example:**
```bash
./create_image_Azure.sh dummy-project-id \
  --resource-group=chronos-test \
  --machine-type=Standard_D4s_v4 \
  --disk-size=30 \
  --zone=uksouth
```

---

## 2. Create Experiment Instances and VMs

This script automatically creates the VNet and subnets if missing, then launches the specified number of Azure VMs using the Chronos base image, and sets up QEMU VMs on them that can ping each other in a mesh network.

**Example usage:**
```bash
./create_instances_Azure.sh \
  --resource-group <resource-group> \
  --location <location> \
  --vm-size <azure-vm-type> \
  --instance-count <azure-vm-count> \
  --vm-per-instance <qemu-vm-per-azure-vm> \
  --secondary-ip-count <secondary-private-ip-count>
```
**Parameter description:**
- `--resource-group`: Azure resource group name (required)
- `--location`: Azure region, e.g., `uksouth` (required)
- `--vm-size`: Azure VM type, e.g., `Standard_D2s_v3` (required)
- `--instance-count`: Number of Azure VMs to launch (required)
- `--vm-per-instance`: Number of QEMU VMs per Azure VM (optional, see script default)
- `--secondary-ip-count`: Number of extra private IPs per VM (optional)

**Full example:**
```bash
./create_instances_Azure.sh \
  --resource-group chronos-test \
  --location uksouth \
  --vm-size Standard_D2s_v3 \
  --instance-count 2 \
  --secondary-ip-count 2
```

---

## 3. Clean Up Resources

Delete all experiment resources except the base image and image gallery.

**Example usage:**
```bash
./delete_chronos_resources.sh --resource-group <resource-group>
```
**Parameter description:**
- `--resource-group`: Azure resource group name (required)

---

## Dependencies

- Azure CLI (must run `az login` first)
- GitHub account and token saved in `./git-credentials` (format: username:token)
- Base image created (see `create_image_Azure.sh`)

---

## Getting Parameter Descriptions

For detailed parameter descriptions (when `--help` is implemented), run:
```bash
./create_image_Azure.sh --help
./create_instances_Azure.sh --help
./delete_chronos_resources.sh --help
```
