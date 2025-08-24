#!/bin/bash
set -eou pipefail
# Create a GCP base image with the Chronos kernel modules
source_image="Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest"
#zone="europe-west4-a"
zone="uksouth"
image_description="Auto-generated Chronos Base Image"
machine_type="Standard_D4s_v3"
ssh_username="azureuser"
disk_size=30

# Network configuration
vnet_name="myVnet"
vm_subnet_name="main-subnet"
bastion_subnet_name="AzureBastionSubnet"
bastion_name="chronos-bastion"
bastion_public_ip_name="chronos-bastion-pip"

kernel_repo="ujjwalpawar/chronos-kernel"
tsc_repo="ujjwalpawar/fake_tsc"
kernel_link="https://github.com/${kernel_repo}.git"
tsc_link="https://github.com/${tsc_repo}.git"

gallery_name="chronosGallery"
image_definition="chronosBaseImage"
image_version="1.0.0"

# Color (disable if not a TTY)
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
YELLOW=$'\033[0;33m'
NC=$'\033[0m' # No Color
if ! test -t 1; then
    RED=""
    GREEN=""
    BLUE=""
    YELLOW=""
    NC=""
fi

################################################################################
#
# Utility functions
#
################################################################################

# Print an error message. Drop-in substitute for printf.
function error() {
    printf "${RED}$1${NC}\n" "${@:2}"
}

# Print a success message. Drop-in substitute for printf.
function success() {
    printf "${GREEN}$1${NC}\n" "${@:2}"
}

# Print an info message. Drop-in substitute for printf.
function info() {
    printf "${BLUE}$1${NC}\n" "${@:2}"
}

# Indent the output of a command, making stdout plain and stderr yellow
function indented() {
    "$@" > >(sed 's/^/  ┃ /') 2> >(sed "s/^/${YELLOW}  ┃ /; s/$/${NC}/" >&2)
    local exit_code=$?
    return $exit_code
}

################################################################################
#
# Command-line argument parsing
#
################################################################################

# Handle command-line arguments. To allow positional and optional arguments to
# be mixed, we first parse all optional arguments, moving all non-flags into
# the positional arguments array. Then, we parse the positional arguments.
positionals=()

#
while test $# -gt 0; do
    case "$1" in
        -h|--help)
            echo "create_image_Azure.sh - create an Azure base image with the Chronos kernel modules"
            echo ""
            echo "Usage:"
            echo "  ./create_image_Azure.sh <DUMMY_PROJECT_ID> --resource-group=<resource-group> [options]"
            echo ""
            echo "Options:"
            echo "  -h, --help                   Show this help message and exit"
            echo "  -z, --zone=<zone>            Specify Azure region/zone (default: uksouth)"
            echo "  -m, --machine-type=<type>    Specify Azure VM size (default: Standard_D4s_v3)"
            echo "  -d, --disk-size=<size>       Specify the OS disk size in GB (default: 30)"
            echo "  --resource-group=<name>      Specify Azure resource group (required)"
            echo ""
            echo "Arguments:"
            echo "  <DUMMY_PROJECT_ID>           Required dummy argument (ignored in Azure, for compatibility)"
            echo ""
            echo "Example:"
            echo "  ./create_image_Azure.sh dummy-project-id --resource-group=chronos-test --machine-type=Standard_D4s_v4 --disk-size=30 --zone=uksouth"
            echo ""
            echo "Environment:"
            echo "  resource_group             Must be set (e.g., resource_group=chronos-test)"
            exit 0
            ;;

        -z)
            shift
            if test $# -gt 0; then
                zone=$1
            else
                echo "no zone for -z argument specified!"
                exit 1
            fi
            shift
            ;;
        --zone*)
            zone=$(echo $1 | sed -e 's/^[^=]*=//g')
            shift
            ;;
        -m)
            shift
            if test $# -gt 0; then
                machine_type=$1
            else
                echo "no machine type for -m argument specified!"
                exit 1
            fi
            shift
            ;;
        --machine-type*)
            machine_type=$(echo $1 | sed -e 's/^[^=]*=//g')
            shift
            ;;
        -d)
            shift
            if test $# -gt 0; then
                disk_size=$1
            else
                echo "no disk size for -d argument specified!"
                exit 1
            fi
            shift
            ;;
        --disk-size*)
            disk_size=$(echo $1 | sed -e 's/^[^=]*=//g')
            shift
            ;;

          # Add --resource-group option for Azure
         --resource-group)
                    shift
                    if test $# -gt 0; then
                        resource_group=$1
                    else
                        echo "no resource group specified with --resource-group"
                        exit 1
                    fi
                    shift
                    ;;
                --resource-group=*)
                    resource_group=$(echo "$1" | sed -e 's/^[^=]*=//g')
                    shift
                    ;;
        *)
            positionals+=("$1")
            shift
            ;;
    esac
done

# Set the positional arguments to the remaining arguments
set -- ${positionals[@]+"${positionals[@]}"}

if test $# -ne 1; then
    error "Incorrect number of arguments provided. Run with -h for help."
    exit 1
fi

project_id=$1

################################################################################
#
# Input validation
#
################################################################################

# Check if the user has provided a project ID
if [ -z "$project_id" ]; then
    error "No project ID provided. Run with -h for help."
    exit 1
fi


# 1 Authenticate az if not already done
if ! az account show &> /dev/null;
then
    error "Azure CLI not authenticated, starting az login procedure"
    indented az login
fi

echo "This script may fail for various reasons. When this happens, "
echo "you may need to manually clean up resources (VPC, instances)."


# 2 Check if the user has provided a resource group
# Validate that the resource_group is set
if [ -z "${resource_group:-}" ]; then
    error "No resource group specified. Use --resource-group=<name> or export resource_group=<name>."
    exit 1
fi

# Check if resource group exists
if ! az group show --name "${resource_group}" &> /dev/null; then
    info "Azure resource group '${resource_group}' not found. Creating it in '${zone}'..."
    indented az group create --name "${resource_group}" --location "${zone}"
fi

# Create virtual network if it doesn't exist
if ! az network vnet show --resource-group "${resource_group}" --name "${vnet_name}" &> /dev/null; then
    info "Creating virtual network: ${vnet_name}"
    indented az network vnet create \
        --resource-group "${resource_group}" \
        --name "${vnet_name}" \
        --address-prefix 10.0.0.0/8 \
        --location "${zone}"
fi

# Create VM subnet if it doesn't exist
if ! az network vnet subnet show --resource-group "${resource_group}" --vnet-name "${vnet_name}" --name "${vm_subnet_name}" &> /dev/null; then
    info "Creating VM subnet: ${vm_subnet_name}"
    indented az network vnet subnet create \
        --resource-group "${resource_group}" \
        --vnet-name "${vnet_name}" \
        --name "${vm_subnet_name}" \
        --address-prefix 10.0.1.0/24
fi

# Create Bastion subnet if it doesn't exist
if ! az network vnet subnet show --resource-group "${resource_group}" --vnet-name "${vnet_name}" --name "${bastion_subnet_name}" &> /dev/null; then
    info "Creating Bastion subnet: ${bastion_subnet_name}"
    indented az network vnet subnet create \
        --resource-group "${resource_group}" \
        --vnet-name "${vnet_name}" \
        --name "${bastion_subnet_name}" \
        --address-prefix 10.0.0.0/27
fi

# Create public IP for Bastion if it doesn't exist
if ! az network public-ip show --resource-group "${resource_group}" --name "${bastion_public_ip_name}" &> /dev/null; then
    info "Creating public IP for Bastion: ${bastion_public_ip_name}"
    indented az network public-ip create \
        --resource-group "${resource_group}" \
        --name "${bastion_public_ip_name}" \
        --sku Standard \
        --location "${zone}"
fi

# Create Bastion host if it doesn't exist
if ! az network bastion show --resource-group "${resource_group}" --name "${bastion_name}" &> /dev/null; then
    info "Creating Azure Bastion host: ${bastion_name}"
    indented az network bastion create \
        --resource-group "${resource_group}" \
        --name "${bastion_name}" \
        --public-ip-address "${bastion_public_ip_name}" \
        --vnet-name "${vnet_name}" \
        --location "${zone}"
fi

# 3 Check if the required Azure resource providers are registered
for ns in Microsoft.Network Microsoft.Compute Microsoft.Storage; do
    if [[ $(az provider show --namespace $ns --query "registrationState" -o tsv) != "Registered" ]]; then
        info "Registering Azure resource provider: $ns"
        az provider register --namespace "$ns"
    fi
done





################################################################################
#
# Base image creation
#
################################################################################

info "Checking if kernel and tsc repos are public or need credentials"
# Check if either of the repos are not publicly accessible, and if so, ask for
# GitHub credentials to clone them. If the credentials are already provided in
# git-credentials, use them to clone the repos.
if ! curl -s -L --head "${kernel_link}" | grep "HTTP/2 200" &> /dev/null ||
   ! curl -s -L --head "${tsc_link}" | grep "HTTP/2 200" &> /dev/null;
then
  info "One or both of the repositories are private. Attempting to clone them with credentials."
    # Ask for GitHub credentials unless they already exist in ./git-credentials
    if ! test -f ./git-credentials;
    then
        info "The Azure instances will need to clone the following private repositories:"
        info "  - ${kernel_link}"
        info "  - ${tsc_link}"
        echo "Please provide your GitHub username and a personal access token to continue."
        read -r github_username
        read -r -s github_token
        echo ""
        info "Saving credentials to ./git-credentials"
        echo "$github_username:$github_token" > ./git-credentials
    else
        info "Reading GitHub credentials from ./git-credentials"
        github_username=$(cut -d: -f1 ./git-credentials)
        github_token=$(cut -d: -f2 ./git-credentials)
        info "Using existing credentials to clone the repositories"
    fi
    # Step 3: update clone URLs to include token
    # Set the clone URLs to use the credentials instead of public link
    kernel_link="https://${github_username}:${github_token}@github.com/${kernel_repo}.git"
    tsc_link="https://${github_username}:${github_token}@github.com/${tsc_repo}.git"
#    info "Using private kernel repo link: ${kernel_link}"
#    info "Using private tsc repo link: ${tsc_link}"

fi

#

# Create RSA keypair for SSH into the instance unless one already exists
if ! [ -f azure-key ]; then
    info "Creating RSA keypair for SSH into the instance"
    indented ssh-keygen -t rsa -f azure-key -C "${ssh_username}@computer" -N "" -q

        # Azure expects pure OpenSSH format, do NOT prepend username
        # azure-key.pub remains unmodified
fi


# Create random uuid for the VM name so it won't clash
uuid=$(openssl rand -hex 4)

# This is the name of the instance to build the image from
vm_name="chronos-base-$uuid"
info "Creating instance with name %s" "$vm_name"

# 2 Create an Azure VM instance using these parameters
indented az vm create \
    --resource-group "${resource_group}" \
    --name "${vm_name}" \
    --image "${source_image}" \
    --size "${machine_type}" \
    --admin-username "${ssh_username}" \
    --ssh-key-values azure-key.pub \
    --os-disk-name "${vm_name}-osdisk" \
    --tags description="${image_description}" \
    --enable-secure-boot false \
    --public-ip-address "" \
    --vnet-name "${vnet_name}" \
    --subnet "${vm_subnet_name}" \
    --verbose

#done
# 3 Wait for the VM to be created by checking its provisioning state
info "Waiting for VM to be provisioned..."
while true; do
    vm_state=$(az vm show --resource-group "${resource_group}" --name "${vm_name}" --query "provisioningState" -o tsv)
    if [ "$vm_state" = "Succeeded" ]; then
        success "VM provisioned successfully"
        break
    fi
    info "VM provisioning state: ${vm_state}. Waiting..."
    sleep 10
done


################################################################################
#
# Instance setup
#
################################################################################

# Get the private IP of the instance
private_ip=$(az vm show \
    --resource-group "${resource_group}" \
    --name "${vm_name}" \
    --show-details \
    --query privateIps \
    --output tsv)
info "Private IP of instance: %s" "${private_ip}"

# Clone the kernel and fake_tsc repositories in the instance
info "Cloning the kernel and fake_tsc repositories in the instance"
indented az vm extension set \
    --resource-group "${resource_group}" \
    --vm-name "${vm_name}" \
    --name customScript \
    --publisher Microsoft.Azure.Extensions \
    --settings "{\"commandToExecute\": \"cd /home/azureuser && git clone ${kernel_link} chronos-kernel && git clone ${tsc_link} fake_tsc\"}"

# Use Custom Script Extension to execute base_image_setup.sh
info "Download and execute base_image_setup.sh (Compiling the kernel may take 1h+ depending on VM performance)"
az vm extension set \
    --resource-group "${resource_group}" \
    --vm-name "${vm_name}" \
    --name customScript \
    --publisher Microsoft.Azure.Extensions \
    --settings "{\"fileUris\": [\"https://raw.githubusercontent.com/xyf2002/Chronos-Azure/main/image_scripts/base_image_setup.sh\"], \"commandToExecute\": \"  bash base_image_setup.sh\"}"

az vm extension show \
  --resource-group "${resource_group}" \
  --vm-name "${vm_name}" \
  --name customScript \
  --query "instanceView.statuses[?code=='ProvisioningState/succeeded'].message" \
  --output tsv

# Use Custom Script Extension to update initramfs and grub
#info "Updating initramfs and grub for custom kernel"
#indented az vm extension set \
#    --resource-group "${resource_group}" \
#    --vm-name "${vm_name}" \
#    --name customScript \
#    --publisher Microsoft.Azure.Extensions \
#    --settings "{\"commandToExecute\": \"sudo update-initramfs -c -k all && sudo update-grub\"}"
indented az vm extension set \
    --resource-group "${resource_group}" \
    --vm-name "${vm_name}" \
    --name customScript \
    --publisher Microsoft.Azure.Extensions \
    --settings "{\"commandToExecute\": \"sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=\\\"Advanced options for Ubuntu>Ubuntu, with Linux 5.15.160+\\\"/' /etc/default/grub && sudo update-initramfs -c -k all && sudo update-grub\"}"

# Use Custom Script Extension to reboot the VM
info "Rebooting instance"
az vm restart --resource-group "${resource_group}" --name "${vm_name}"

# Wait for VM to reboot
info "Waiting for VM to complete reboot process"
sleep 30

# Check VM power state after reboot
info "Checking VM power state after reboot"
for attempt in {1..20}; do
    vm_state=$(az vm get-instance-view \
        --resource-group "${resource_group}" \
        --name "${vm_name}" \
        --query "instanceView.statuses[?code=='PowerState/running']" \
        --output tsv 2>/dev/null)

    if [[ -n "$vm_state" ]]; then
        info "VM is running (attempt $attempt/20)"
        break
    else
        echo "VM not running yet, waiting... (attempt $attempt/20)"
        if [[ $attempt -eq 20 ]]; then
            error "VM failed to restart properly. Checking boot diagnostics..."
            az vm boot-diagnostics get-boot-log \
                --resource-group "${resource_group}" \
                --name "${vm_name}" || echo "Boot diagnostics not available"
            exit 1
        fi
        sleep 15
    fi
done

# Use Custom Script Extension to check kernel version
info "Checking that the custom kernel is being used"
kernel=$(az vm extension set \
    --resource-group "${resource_group}" \
    --vm-name "${vm_name}" \
    --name customScript \
    --publisher Microsoft.Azure.Extensions \
    --settings "{\"commandToExecute\": \"uname -r\"}" \
    --query "instanceView.statuses[?code=='ProvisioningState/succeeded'].message" \
    --output tsv | tail -n 1)

if [[ $kernel == *"azure"* ]]; then
    error "Kernel is not the custom kernel, it is: ${kernel}. Exiting."
    exit 1
else
    success "Custom kernel detected: ${kernel}"
fi

################################################################################
#
# Image creation
#
################################################################################


# 7 Stop the instance || gcloud compute instances stop
info "Stopping instance to create image"
indented az vm deallocate --resource-group "${resource_group}" --name "${vm_name}"


# Generalize VM before creating image
info "Generalizing the VM to allow image creation"
indented az vm generalize --resource-group "${resource_group}" --name "${vm_name}"


# 8 Create an image from the instance, naming it the same as the instance
info "Creating image from instance"
if ! az sig show --resource-group "${resource_group}" --gallery-name "${gallery_name}" &> /dev/null; then
    info "Creating Shared Image Gallery: ${gallery_name}"
    indented az sig create --resource-group "${resource_group}" --gallery-name "${gallery_name}" --location "${zone}"
fi

# create Image Definition
if ! az sig image-definition show --resource-group "${resource_group}" --gallery-name "${gallery_name}" --gallery-image-definition "${image_definition}" &> /dev/null; then
    info "Creating Image Definition: ${image_definition}"
    indented az sig image-definition create \
        --resource-group "${resource_group}" \
        --gallery-name "${gallery_name}" \
        --gallery-image-definition "${image_definition}" \
        --publisher chronos \
        --offer chronos-offer \
        --sku chronos-sku \
        --os-type Linux \
        --os-state generalized \
        --hyper-v-generation V2 \
        --features SecurityType=TrustedLaunch #securityType should be set same as the VM
fi

# Get the VM ID
vm_id=$(az vm show \
  --resource-group "${resource_group}" \
  --name "${vm_name}" \
  --query id \
  --output tsv)


# create Image Version
info "Creating Shared Image Gallery version from VM"
indented az sig image-version create \
    --resource-group "${resource_group}" \
    --gallery-name "${gallery_name}" \
    --gallery-image-definition "${image_definition}" \
    --gallery-image-version "${image_version}" \
    --virtual-machine "${vm_id}" \
    --location "${zone}"


# 9 delete the instance
info "Deleting instance"
indented az vm delete --resource-group "${resource_group}" --name "${vm_name}" --yes


success "Complete! Image created successfully."
success "The image is named ${vm_name}"
success "You can now create instances using create_instances.sh."
