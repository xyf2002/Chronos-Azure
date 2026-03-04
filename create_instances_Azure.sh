#!/bin/bash
################################################################################
# Step 1: (GitHub credentials removed — repos are public)
################################################################################

################################################################################
# Step 1.5: Setup SSH keys
################################################################################
SSH_KEY_FILE="./azure-key"
SSH_PUB_KEY_FILE="./azure-key.pub"
AZURE_KEY_FILE="./azure-key"
AZURE_KEY_PUB_FILE="./azure-key.pub"

################################################################################
# Step 2: Define Azure instance parameters
################################################################################

# Default values
RESOURCE_GROUP="chronos-test"
LOCATION="uksouth"
VM_SIZE="Standard_D8_v5"
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
#IMAGE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/chronos-test/providers/Microsoft.Compute/galleries/chronosGallery/images/chronosBaseImage/versions/1.0.0"
#IMAGE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/chronos-template/providers/Microsoft.Compute/galleries/chronosGalleryTemplate/images/chronosBaseImage/versions/1.0.0"
standard_image="Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest"
IMAGE="Canonical:0001-com-ubuntu-server-focal:20_04-lts-gen2:latest"

SECURITY_TYPE="${SECURITY_TYPE:-}"   # set env var if you want: TrustedLaunch / ConfidentialVM

SECURITY_ARGS=()
if [[ -n "$SECURITY_TYPE" ]]; then
  SECURITY_ARGS+=(--security-type "$SECURITY_TYPE")
fi

INSTANCE_COUNT=1
VM_NAME_PREFIX="ins"
PROXY_TYPE=""
PROXY_ENABLED=false
PROXY_COUNT=1
GLOBALSC_TYPE=""
DISK_SIZE=300  # Default disk size in GB
BASTION_NAME="chronos-bastion"
BASTION_ENABLE_TUNNELING="${BASTION_ENABLE_TUNNELING:-true}"
BASTION_ENABLE_IP_CONNECT="${BASTION_ENABLE_IP_CONNECT:-true}"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            echo "create_instances_Azure.sh - create Azure VMs and configure Chronos experiment"
            echo ""
            echo "Usage:"
            echo "  ./create_instances_Azure.sh --resource-group <resource-group> --location <location> --vm-size <vm-size> --instance-count <count> [--secondary-ip-count <count>] [--vm-per-instance <count>] [--proxy-type <type>] [--globalsc-type <type>] [--disk-size <size>]"
            echo ""
            echo "Options:"
            echo "  --help, -h                      Show this help message and exit"
            echo "  --resource-group <name>          Azure resource group name (default: chronos-test)"
            echo "  --location <location>            Azure region, e.g., uksouth (default: uksouth)"
            echo "  --vm-size <type>                 Azure VM size, e.g., Standard_D2s_v3 (default: Standard_D2s_v3)"
            echo "  --instance-count <count>         Number of Azure VMs to launch (default: 1)"
            echo "  --secondary-ip-count <count>     Number of extra private IPs on insX NIC1 (10.1.i.x) only (default: 2)"
            echo "  --vm-per-instance <count>        Number of QEMU VMs per Azure VM (default: 2)"
            echo "  --vm-name-prefix <prefix>        Prefix for VM names (default: ins)"
            echo "  --proxy-type <type>             VM size for proxy machine (enables proxy creation)"
            echo "  --proxy-count <n>               Number of proxy VMs to create (default: 1, requires --proxy-type)"
            echo "  --globalsc-type <type>          VM size for Global-SC machine (default: --proxy-type if set, else --vm-size)"
            echo "  --disk-size <size>              OS disk size in GB (default: 30)
  --ssh-key <path>               Path to existing private key (default: ./azure-key); generates if absent"
            echo ""
            echo "Example:"
            echo "  ./create_instances_Azure.sh --resource-group chronos-test --location uksouth --vm-size Standard_D2s_v3 --instance-count 2 --secondary-ip-count 2 --proxy-type Standard_D2s_v3 --globalsc-type Standard_D4s_v3 --proxy-count 2 --disk-size 50"
            exit 0
            ;;
        --resource-group)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        --resource-group=*)
            RESOURCE_GROUP="${1#*=}"
            shift
            ;;
        --location)
            LOCATION="$2"
            shift 2
            ;;
        --location=*)
            LOCATION="${1#*=}"
            shift
            ;;
        --vm-size)
            VM_SIZE="$2"
            shift 2
            ;;
        --vm-size=*)
            VM_SIZE="${1#*=}"
            shift
            ;;
        --instance-count)
            INSTANCE_COUNT="$2"
            shift 2
            ;;
        --instance-count=*)
            INSTANCE_COUNT="${1#*=}"
            shift
            ;;
        --secondary-ip-count)
            MAX_SECONDARY_IPS="$2"
            shift 2
            ;;
        --secondary-ip-count=*)
            MAX_SECONDARY_IPS="${1#*=}"
            shift
            ;;
        --vm-per-instance)
            MAX_SECONDARY_IPS="$2"
            shift 2
            ;;
        --vm-per-instance=*)
            MAX_SECONDARY_IPS="${1#*=}"
            shift
            ;;
        --vm-name-prefix)
            VM_NAME_PREFIX="$2"
            shift 2
            ;;
        --vm-name-prefix=*)
            VM_NAME_PREFIX="${1#*=}"
            shift
            ;;
        --proxy-type)
            PROXY_TYPE="$2"
            PROXY_ENABLED=true
            shift 2
            ;;
        --proxy-type=*)
            PROXY_TYPE="${1#*=}"
            PROXY_ENABLED=true
            shift
            ;;
        --proxy-count)
            PROXY_COUNT="$2"
            shift 2
            ;;
        --proxy-count=*)
            PROXY_COUNT="${1#*=}"
            shift
            ;;
        --globalsc-type)
            GLOBALSC_TYPE="$2"
            shift 2
            ;;
        --globalsc-type=*)
            GLOBALSC_TYPE="${1#*=}"
            shift
            ;;
        --disk-size)
            DISK_SIZE="$2"
            shift 2
            ;;
        --disk-size=*)
            DISK_SIZE="${1#*=}"
            shift
            ;;
        --ssh-key)
            SSH_KEY_FILE="$2"
            SSH_PUB_KEY_FILE="$2.pub"
            AZURE_KEY_FILE="$2"
            AZURE_KEY_PUB_FILE="$2.pub"
            shift 2
            ;;
        --ssh-key=*)
            _v="${1#*=}"
            SSH_KEY_FILE="$_v"
            SSH_PUB_KEY_FILE="$_v.pub"
            AZURE_KEY_FILE="$_v"
            AZURE_KEY_PUB_FILE="$_v.pub"
            shift
            ;;
        *)
            break
            ;;
    esac
done

# Generate key pair only if the private key file does not already exist
if [ ! -f "$SSH_KEY_FILE" ]; then
    echo "Generating SSH key pair at $SSH_KEY_FILE..."
    ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_FILE" -N "" -C "azure-vm-key"
    chmod 600 "$SSH_KEY_FILE"
    chmod 644 "$SSH_PUB_KEY_FILE"
else
    echo "Using existing SSH key: $SSH_KEY_FILE"
fi
echo "Using SSH public key: $AZURE_KEY_PUB_FILE"

VNET_NAME="myVnet"
SUBNET_NAME="main-subnet"
VNET_PREFIX="10.0.0.0/8"
#SUBNET_PREFIX="10.1.0.0/24"
SUBNET_PREFIX="10.0.1.0/24"

# Default MAX_SECONDARY_IPS if not set by command line args above
MAX_SECONDARY_IPS=${MAX_SECONDARY_IPS:-2}
# Optional pause between each IP config create (seconds). Set >0 only if you hit API throttling.
IPCONFIG_DELAY_SEC=${IPCONFIG_DELAY_SEC:-0}
# Try to add all secondary IP configs in one NIC update call for speed.
# Falls back to per-IP create loop on failure.
IPCONFIG_BULK_MODE=${IPCONFIG_BULK_MODE:-true}


echo "Checking if resource group '$RESOURCE_GROUP' exists..."
if ! az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1; then
    echo "Resource group '$RESOURCE_GROUP' not found. Creating it..."
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

    # Wait for resource group to be ready
    for attempt in {1..10}; do
        if az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1; then
            echo "Resource group '$RESOURCE_GROUP' created successfully."
            break
        else
            echo "Waiting for resource group to be ready... (${attempt}/10)"
            sleep 3
        fi
        if [ $attempt -eq 10 ]; then
            echo "ERROR: Resource group '$RESOURCE_GROUP' creation failed"
            exit 1
        fi
    done
else
    echo "Resource group '$RESOURCE_GROUP' already exists."
fi

# Create virtual network and subnet
echo "Checking if VNet ${VNET_NAME} exists..."
if ! az network vnet show --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" >/dev/null 2>&1; then
    echo "Creating VNet ${VNET_NAME}..."
    az network vnet create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$VNET_NAME" \
      --location "$LOCATION" \
      --address-prefix "$VNET_PREFIX" \
      --subnet-name "$SUBNET_NAME" \
      --subnet-prefix "$SUBNET_PREFIX"
else
    echo "VNet ${VNET_NAME} already exists."

    # Check if main subnet exists
        if ! az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$SUBNET_NAME" >/dev/null 2>&1; then
        echo "Creating main subnet ${SUBNET_NAME} with prefix ${SUBNET_PREFIX}..."
        az network vnet subnet create \
          --resource-group "$RESOURCE_GROUP" \
          --vnet-name "$VNET_NAME" \
          --name "$SUBNET_NAME" \
          --address-prefix "$SUBNET_PREFIX"
    else
        echo "Main subnet ${SUBNET_NAME} already exists."
    fi
fi

# Wait for subnet to be fully ready before proceeding
echo "Verifying subnet ${SUBNET_NAME} is ready..."
for subnet_wait in {1..15}; do
  if az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$SUBNET_NAME" >/dev/null 2>&1; then
    echo "Subnet ${SUBNET_NAME} is ready."
    break
  else
    echo "Waiting for subnet to be ready... (${subnet_wait}/15)"
    sleep 5
  fi
  if [ $subnet_wait -eq 15 ]; then
    echo "ERROR: Subnet ${SUBNET_NAME} was not created successfully"
    exit 1
  fi
done

################################################################################
# Step 2.5: Create Azure Bastion Subnet and Service
################################################################################
BASTION_PIP_NAME="chronos-bastion-pip"
BASTION_SUBNET_NAME="AzureBastionSubnet"
BASTION_SUBNET_PREFIX="10.0.0.0/27"

# Check if Bastion subnet already exists
if ! az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$BASTION_SUBNET_NAME" >/dev/null 2>&1; then
    echo "Creating Azure Bastion subnet..."
    az network vnet subnet create \
      --resource-group "$RESOURCE_GROUP" \
      --vnet-name "$VNET_NAME" \
      --name "$BASTION_SUBNET_NAME" \
      --address-prefix "$BASTION_SUBNET_PREFIX"
else
    echo "Azure Bastion subnet already exists."
fi

# Check if Bastion already exists
BASTION_STATE=$(az network bastion show --resource-group "$RESOURCE_GROUP" --name "$BASTION_NAME" --query "provisioningState" -o tsv 2>/dev/null)
# Fix for WSL
BASTION_STATE=$(echo "$BASTION_STATE" | tr -d '\r')
if [[ "$BASTION_STATE" == "Succeeded" ]]; then
  echo "Azure Bastion ${BASTION_NAME} already exists and is ready (state: $BASTION_STATE)."
  echo "Ensuring Bastion native SSH support is enabled..."
  az network bastion update \
    --resource-group "$RESOURCE_GROUP" \
    --name "$BASTION_NAME" \
    --sku Standard \
    --enable-tunneling "$BASTION_ENABLE_TUNNELING" \
    --enable-ip-connect "$BASTION_ENABLE_IP_CONNECT" \
    --no-wait \
    --only-show-errors || echo "Warning: Could not update Bastion settings right now."
elif [[ -n "$BASTION_STATE" ]] && [[ "$BASTION_STATE" != "Failed" ]]; then
  echo "Azure Bastion ${BASTION_NAME} is currently provisioning (state: $BASTION_STATE). Continuing without wait..."
  # Don't wait here, let the script continue
else
  # Bastion doesn't exist or failed, create it
  # Check if Bastion Public IP already exists
  if ! az network public-ip show --resource-group "$RESOURCE_GROUP" --name "$BASTION_PIP_NAME" >/dev/null 2>&1; then
    echo "Creating Bastion Public IP ${BASTION_PIP_NAME}..."
    az network public-ip create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$BASTION_PIP_NAME" \
      --location "$LOCATION" \
      --sku Standard \
      --allocation-method Static
  else
    echo "Bastion Public IP ${BASTION_PIP_NAME} already exists."
  fi

  echo "Creating Azure Bastion ${BASTION_NAME} (no-wait mode)..."
  az network bastion create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$BASTION_NAME" \
    --location "$LOCATION" \
    --vnet-name "$VNET_NAME" \
    --public-ip-address "$BASTION_PIP_NAME" \
    --sku Standard \
    --enable-tunneling "$BASTION_ENABLE_TUNNELING" \
    --enable-ip-connect "$BASTION_ENABLE_IP_CONNECT" \
    --no-wait

  echo "Bastion creation initiated in background. You can check status in Azure Portal."
fi

# Optional: Quick status check without blocking
echo "Current Bastion status check..."
CURRENT_STATE=$(az network bastion show --resource-group "$RESOURCE_GROUP" --name "$BASTION_NAME" --query "provisioningState" -o tsv 2>/dev/null || echo "Not found or creating")
echo "Bastion ${BASTION_NAME} current state: $CURRENT_STATE"

# Create NAT Gateway Public IP
NAT_PUBLIC_IP_NAME="chronos-nat-pip"
echo "Creating NAT Gateway Public IP ${NAT_PUBLIC_IP_NAME}..."
az network public-ip create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$NAT_PUBLIC_IP_NAME" \
  --location "$LOCATION" \
  --sku Standard \
  --allocation-method Static

# Create NAT Gateway
NAT_GATEWAY_NAME="chronos-nat-gw"
echo "Creating NAT Gateway ${NAT_GATEWAY_NAME}..."
az network nat gateway create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$NAT_GATEWAY_NAME" \
  --location "$LOCATION" \
  --public-ip-addresses "$NAT_PUBLIC_IP_NAME" \
  --idle-timeout 4

# Associate NAT Gateway with the subnet
echo "Associating NAT Gateway ${NAT_GATEWAY_NAME} with subnet ${SUBNET_NAME}..."
# Double-check subnet exists before association
if ! az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$SUBNET_NAME" >/dev/null 2>&1; then
  echo "ERROR: Subnet ${SUBNET_NAME} not found. Cannot associate NAT Gateway."
  exit 1
fi

az network vnet subnet update \
  --resource-group "$RESOURCE_GROUP" \
  --vnet-name "$VNET_NAME" \
  --name "$SUBNET_NAME" \
  --nat-gateway "$NAT_GATEWAY_NAME"

echo "NAT Gateway ${NAT_GATEWAY_NAME} successfully associated with subnet ${SUBNET_NAME}"

for attempt in {1..10}; do
  if az network vnet show --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" >/dev/null 2>&1 && \
     az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$SUBNET_NAME" >/dev/null 2>&1; then
    echo "VNet and Subnet are ready."
    break
  else
    echo "Waiting for VNet/Subnet to be ready... (${attempt}/10)"
    sleep 3
  fi
done

################################################################################
# Step 2.6b: Route table for nested QEMU subnet reachability
################################################################################
ROUTE_TABLE_NAME="chronos-innervm-rt"
echo "Ensuring route table ${ROUTE_TABLE_NAME} exists..."
if ! az network route-table show --resource-group "$RESOURCE_GROUP" --name "$ROUTE_TABLE_NAME" >/dev/null 2>&1; then
  az network route-table create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ROUTE_TABLE_NAME" \
    --location "$LOCATION" \
    --output none
fi

echo "Programming routes 10.2.i.0/24 -> 10.1.i.5 in ${ROUTE_TABLE_NAME}..."
for (( i=0; i<INSTANCE_COUNT; i++ )); do
  INNER_PREFIX="10.2.${i}.0/24"
  NEXT_HOP_IP="10.1.${i}.5"
  ROUTE_NAME="to-inner-${i}"
  az network route-table route create \
    --resource-group "$RESOURCE_GROUP" \
    --route-table-name "$ROUTE_TABLE_NAME" \
    --name "$ROUTE_NAME" \
    --address-prefix "$INNER_PREFIX" \
    --next-hop-type VirtualAppliance \
    --next-hop-ip-address "$NEXT_HOP_IP" \
    --output none
done

################################################################################
# Step 2.7: Create Proxy Subnets and Instances (if enabled)
################################################################################
if [ "$PROXY_ENABLED" = true ]; then
    # Verify SSH key exists before creating any proxy VM
    if [ ! -f "$AZURE_KEY_PUB_FILE" ]; then
        echo "ERROR: SSH public key not found at $AZURE_KEY_PUB_FILE"
        exit 1
    fi

    # Create subnets sequentially (Azure has concurrency issues with subnet creation)
    for (( proxy_idx=0; proxy_idx<PROXY_COUNT; proxy_idx++ )); do
        PROXY_SUBNET_NAME="proxy-subnet-${proxy_idx}"
        PROXY_SUBNET_PREFIX="10.3.$((proxy_idx+1)).0/24"

        echo "Creating proxy subnet ${PROXY_SUBNET_NAME} with prefix ${PROXY_SUBNET_PREFIX}..."
        az network vnet subnet create \
          --resource-group "$RESOURCE_GROUP" \
          --vnet-name "$VNET_NAME" \
          --name "$PROXY_SUBNET_NAME" \
          --address-prefix "$PROXY_SUBNET_PREFIX" \
          --nat-gateway "$NAT_GATEWAY_NAME" \
          --route-table "$ROUTE_TABLE_NAME"

        for proxy_subnet_wait in {1..15}; do
          if az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$PROXY_SUBNET_NAME" >/dev/null 2>&1; then
            echo "Proxy subnet ${PROXY_SUBNET_NAME} is ready."
            break
          else
            echo "Waiting for proxy subnet to be ready... (${proxy_subnet_wait}/15)"
            sleep 5
          fi
          if [ $proxy_subnet_wait -eq 15 ]; then
            echo "ERROR: Proxy subnet ${PROXY_SUBNET_NAME} was not created successfully"
            exit 1
          fi
        done

        # Ensure route-table association is present even on reruns.
        az network vnet subnet update \
          --resource-group "$RESOURCE_GROUP" \
          --vnet-name "$VNET_NAME" \
          --name "$PROXY_SUBNET_NAME" \
          --route-table "$ROUTE_TABLE_NAME" \
          --output none
    done

    # Create NICs and VMs in parallel (one subshell per proxy)
    for (( proxy_idx=0; proxy_idx<PROXY_COUNT; proxy_idx++ )); do
    (
        PROXY_SUBNET_NAME="proxy-subnet-${proxy_idx}"
        PROXY_VM_NAME="proxy-vm-${proxy_idx}"
        PROXY_NIC_NAME="proxy-nic-${proxy_idx}"
        PROXY_IP="10.3.$((proxy_idx+1)).5"

        echo "Creating proxy NIC ${PROXY_NIC_NAME} with IP ${PROXY_IP}..."
        az network nic create \
          --resource-group "$RESOURCE_GROUP" \
          --name "$PROXY_NIC_NAME" \
          --vnet-name "$VNET_NAME" \
          --subnet "$PROXY_SUBNET_NAME" \
          --private-ip-address "$PROXY_IP" \
          --ip-forwarding true

        for verify_attempt in {1..10}; do
          if az network nic show --resource-group "$RESOURCE_GROUP" --name "$PROXY_NIC_NAME" >/dev/null 2>&1; then
            echo "Proxy NIC ${PROXY_NIC_NAME} verified successfully"
            break
          else
            echo "Attempt ${verify_attempt}/10: Proxy NIC ${PROXY_NIC_NAME} not found, waiting..."
            if [ $verify_attempt -eq 10 ]; then
              echo "ERROR: Proxy NIC ${PROXY_NIC_NAME} was not created successfully"
              exit 1
            fi
            sleep 5
          fi
        done

        echo "Creating proxy VM ${PROXY_VM_NAME} with type ${PROXY_TYPE}..."
        az vm create \
          --resource-group "$RESOURCE_GROUP" \
          --name "$PROXY_VM_NAME" \
          --nics "$PROXY_NIC_NAME" \
          --image "$IMAGE" \
          "${SECURITY_ARGS[@]}" \
          --size "$PROXY_TYPE" \
          --location "$LOCATION" \
          --admin-username azureuser \
          --ssh-key-values "$AZURE_KEY_PUB_FILE" \
          --os-disk-name "${PROXY_VM_NAME}-osdisk" \
          --os-disk-size-gb "$DISK_SIZE"

        # Configure SSH and ip_forward on proxy VM
        az vm run-command invoke \
          --resource-group "$RESOURCE_GROUP" \
          --name "$PROXY_VM_NAME" \
          --command-id RunShellScript \
          --scripts "mkdir -p /home/azureuser/.ssh; echo '$(cat ./azure-key.pub)' > /home/azureuser/.ssh/authorized_keys; chown -R azureuser:azureuser /home/azureuser/.ssh; chmod 600 /home/azureuser/.ssh/authorized_keys; echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf; sudo sysctl -p; echo 'Proxy VM ${proxy_idx} configured with IP ${PROXY_IP}'" \
          --output none

        # Wait for proxy VM to be running
        echo "Waiting for proxy VM ${PROXY_VM_NAME} to be fully provisioned..."
        for attempt in {1..30}; do
          VM_STATE=$(az vm get-instance-view \
            --resource-group "$RESOURCE_GROUP" \
            --name "$PROXY_VM_NAME" \
            --query "instanceView.statuses[?code=='PowerState/running']" \
            --output tsv 2>/dev/null)

          if [[ -n "$VM_STATE" ]]; then
            echo "Proxy VM ${PROXY_VM_NAME} is running with IP: ${PROXY_IP}"
            break
          fi

          echo "Attempt ${attempt}/30: Proxy VM ${PROXY_VM_NAME} not ready yet, waiting..."
          if [ $attempt -eq 30 ]; then
            echo "ERROR: Proxy VM ${PROXY_VM_NAME} failed to start properly"
            exit 1
          fi
          sleep 10
        done

        # Copy scripts to proxy VM
        echo "Copying scripts to proxy VM ${PROXY_VM_NAME}..."
        tar -czf /tmp/scripts_${PROXY_VM_NAME}.tar.gz -C . instance_scripts/
        scripts_b64=$(base64 < /tmp/scripts_${PROXY_VM_NAME}.tar.gz)
        az vm run-command invoke \
          --resource-group "$RESOURCE_GROUP" \
          --name "$PROXY_VM_NAME" \
          --command-id RunShellScript \
          --scripts "echo '${scripts_b64}' | base64 -d > /tmp/scripts.tar.gz && cd /home/azureuser && tar -xzf /tmp/scripts.tar.gz && chown -R azureuser:azureuser instance_scripts/ && rm /tmp/scripts.tar.gz" \
          --output none
        rm -f /tmp/scripts_${PROXY_VM_NAME}.tar.gz

        # Execute build_proxy.sh — pass proxy index as 4th argument
        echo "Executing build_proxy.sh on proxy VM ${PROXY_VM_NAME} (index ${proxy_idx})..."
        az vm extension set \
          --resource-group "$RESOURCE_GROUP" \
          --vm-name "$PROXY_VM_NAME" \
          --name CustomScript \
          --publisher Microsoft.Azure.Extensions \
          --settings "{\"commandToExecute\":\"cd /home/azureuser && ./instance_scripts/build_proxy.sh '${INSTANCE_COUNT}' '${proxy_idx}'\"}" \
          --no-wait

        echo "Proxy VM ${PROXY_VM_NAME} (index ${proxy_idx}, IP ${PROXY_IP}) created and build_proxy.sh initiated"
    ) &
    done
    wait
    echo "All ${PROXY_COUNT} proxy VM(s) created successfully"
fi

################################################################################
# Step 2.8: Create Global-SC Subnet (sequential) and Instance (background)
################################################################################
GLOBALSC_SUBNET_NAME="globalsc-subnet"
GLOBALSC_SUBNET_PREFIX="10.4.1.0/24"
GLOBALSC_IP="10.4.1.5"
GLOBALSC_VM_NAME="globalsc-vm"
GLOBALSC_NIC_NAME="globalsc-nic"

if az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$GLOBALSC_SUBNET_NAME" >/dev/null 2>&1; then
    echo "Global-SC subnet ${GLOBALSC_SUBNET_NAME} already exists, skipping."
    az network vnet subnet update \
      --resource-group "$RESOURCE_GROUP" \
      --vnet-name "$VNET_NAME" \
      --name "$GLOBALSC_SUBNET_NAME" \
      --route-table "$ROUTE_TABLE_NAME" \
      --output none
else
    echo "Creating Global-SC subnet ${GLOBALSC_SUBNET_NAME}..."
    if ! az network vnet subnet create \
      --resource-group "$RESOURCE_GROUP" \
      --vnet-name "$VNET_NAME" \
      --name "$GLOBALSC_SUBNET_NAME" \
      --address-prefix "$GLOBALSC_SUBNET_PREFIX" \
      --nat-gateway "$NAT_GATEWAY_NAME" \
      --route-table "$ROUTE_TABLE_NAME"; then
        echo "ERROR: Global-SC subnet creation failed"
        exit 1
    fi
    echo "Global-SC subnet ready."
fi

(
    if az network nic show --resource-group "$RESOURCE_GROUP" --name "$GLOBALSC_NIC_NAME" >/dev/null 2>&1; then
        echo "Global-SC NIC ${GLOBALSC_NIC_NAME} already exists, skipping."
    else
        echo "Creating Global-SC NIC ${GLOBALSC_NIC_NAME} with IP ${GLOBALSC_IP}..."
        az network nic create \
          --resource-group "$RESOURCE_GROUP" \
          --name "$GLOBALSC_NIC_NAME" \
          --vnet-name "$VNET_NAME" \
          --subnet "$GLOBALSC_SUBNET_NAME" \
          --private-ip-address "$GLOBALSC_IP" \
          --ip-forwarding true
    fi

    if az vm show --resource-group "$RESOURCE_GROUP" --name "$GLOBALSC_VM_NAME" >/dev/null 2>&1; then
        echo "Global-SC VM ${GLOBALSC_VM_NAME} already exists, skipping creation."
    else
        echo "Creating Global-SC VM ${GLOBALSC_VM_NAME} with type ${GLOBALSC_TYPE:-${PROXY_TYPE:-$VM_SIZE}}..."
        az vm create \
          --resource-group "$RESOURCE_GROUP" \
          --name "$GLOBALSC_VM_NAME" \
          --nics "$GLOBALSC_NIC_NAME" \
          --image "$IMAGE" \
          "${SECURITY_ARGS[@]}" \
          --size "${GLOBALSC_TYPE:-${PROXY_TYPE:-$VM_SIZE}}" \
          --location "$LOCATION" \
          --admin-username azureuser \
          --ssh-key-values "$AZURE_KEY_PUB_FILE" \
          --os-disk-name "${GLOBALSC_VM_NAME}-osdisk" \
          --os-disk-size-gb "$DISK_SIZE"
    fi

    az vm run-command invoke \
      --resource-group "$RESOURCE_GROUP" \
      --name "$GLOBALSC_VM_NAME" \
      --command-id RunShellScript \
      --scripts "mkdir -p /home/azureuser/.ssh; echo '$(cat ./azure-key.pub)' > /home/azureuser/.ssh/authorized_keys; chown -R azureuser:azureuser /home/azureuser/.ssh; chmod 600 /home/azureuser/.ssh/authorized_keys; echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf; sudo sysctl -p" \
      --output none

    echo "Waiting for Global-SC VM to be running..."
    for attempt in {1..30}; do
        VM_STATE=$(az vm get-instance-view \
          --resource-group "$RESOURCE_GROUP" \
          --name "$GLOBALSC_VM_NAME" \
          --query "instanceView.statuses[?code=='PowerState/running']" \
          --output tsv 2>/dev/null)
        if [[ -n "$VM_STATE" ]]; then
            echo "Global-SC VM is running at ${GLOBALSC_IP}"
            break
        fi
        echo "Attempt ${attempt}/30: Global-SC VM not ready..."
        if [ $attempt -eq 30 ]; then
            echo "ERROR: Global-SC VM failed to start"
            exit 1
        fi
        sleep 10
    done

    echo "Copying scripts to Global-SC VM..."
    tar -czf /tmp/scripts_globalsc.tar.gz -C . instance_scripts/
    scripts_b64=$(base64 < /tmp/scripts_globalsc.tar.gz)
    az vm run-command invoke \
      --resource-group "$RESOURCE_GROUP" \
      --name "$GLOBALSC_VM_NAME" \
      --command-id RunShellScript \
      --scripts "echo '${scripts_b64}' | base64 -d > /tmp/scripts.tar.gz && cd /home/azureuser && tar -xzf /tmp/scripts.tar.gz && chown -R azureuser:azureuser instance_scripts/ && rm /tmp/scripts.tar.gz" \
      --output none
    rm -f /tmp/scripts_globalsc.tar.gz

    echo "Executing build_globalsc.sh on ${GLOBALSC_VM_NAME}..."
    az vm extension set \
      --resource-group "$RESOURCE_GROUP" \
      --vm-name "$GLOBALSC_VM_NAME" \
      --name CustomScript \
      --publisher Microsoft.Azure.Extensions \
      --settings "{\"commandToExecute\":\"cd /home/azureuser && bash ./instance_scripts/build_globalsc.sh '${INSTANCE_COUNT}'\"}" \
      --no-wait

    echo "Global-SC VM created and build_globalsc.sh initiated (IP: ${GLOBALSC_IP})"
) &

################################################################################
# Step 3: Create Azure VMs and configure each VM remotely
################################################################################

# Sequentially create all subnets to avoid concurrency conflicts
# Create instance subnets for all instances
for (( i=0; i<INSTANCE_COUNT; i++ )); do
    # First subnet set (10.1.x.0/24)
    SUBNET_NAME_1="subnet${i}"
    SUBNET_PREFIX_1="10.1.$i.0/24"
    echo "Creating subnet ${SUBNET_NAME_1} with prefix ${SUBNET_PREFIX_1}..."
    az network vnet subnet create \
      --resource-group "$RESOURCE_GROUP" \
      --vnet-name "$VNET_NAME" \
      --name "$SUBNET_NAME_1" \
      --address-prefix "$SUBNET_PREFIX_1" \
      --nat-gateway "$NAT_GATEWAY_NAME" \
      --route-table "$ROUTE_TABLE_NAME" \
      --output none

    # Wait for first subnet creation to complete
    for subnet_attempt in {1..10}; do
      if az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$SUBNET_NAME_1" >/dev/null 2>&1; then
        echo "Subnet ${SUBNET_NAME_1} created successfully with NAT Gateway"
        break
      else
        echo "Waiting for subnet ${SUBNET_NAME_1} to be ready... (${subnet_attempt}/10)"
        sleep 3
      fi
      if [ $subnet_attempt -eq 10 ]; then
        echo "ERROR: Subnet ${SUBNET_NAME_1} was not created successfully"
        exit 1
      fi
    done
    # Ensure route-table association exists on reruns.
    az network vnet subnet update \
      --resource-group "$RESOURCE_GROUP" \
      --vnet-name "$VNET_NAME" \
      --name "$SUBNET_NAME_1" \
      --route-table "$ROUTE_TABLE_NAME" \
      --output none
done

# Add secondary NIC IP configs sequentially on a NIC.
add_secondary_ip_configs() {
  local nic_name="$1"
  local subnet_name="$2"
  local ip_prefix="$3"
  local fail_file="$4"
  local ip_base="$5"
  local subnet_id

  : > "$fail_file"

  if [ "$IPCONFIG_BULK_MODE" = "true" ]; then
    subnet_id=$(az network vnet subnet show \
      --resource-group "$RESOURCE_GROUP" \
      --vnet-name "$VNET_NAME" \
      --name "$subnet_name" \
      --query id \
      --output tsv 2>/dev/null)

    if [ -n "$subnet_id" ]; then
      local -a bulk_cmd
      bulk_cmd=(
        az network nic update
        --resource-group "$RESOURCE_GROUP"
        --name "$nic_name"
        --only-show-errors
        --output none
      )
      local additions=0

      for j in $(seq 1 "$MAX_SECONDARY_IPS"); do
        local sec_ip ipconfig_name existing_count ipcfg_json
        sec_ip="${ip_prefix}.$((ip_base + j))"
        ipconfig_name="ipconfig$((j+1))"

        existing_count=$(az network nic show \
          --resource-group "$RESOURCE_GROUP" \
          --name "$nic_name" \
          --query "length(ipConfigurations[?name=='$ipconfig_name' || privateIPAddress=='$sec_ip'])" \
          --output tsv 2>/dev/null)

        if [ "$existing_count" = "0" ] || [ -z "$existing_count" ]; then
          ipcfg_json=$(printf '{"name":"%s","privateIPAddress":"%s","privateIPAllocationMethod":"Static","subnet":{"id":"%s"}}' \
            "$ipconfig_name" "$sec_ip" "$subnet_id")
          bulk_cmd+=(--add ipConfigurations "$ipcfg_json")
          additions=$((additions + 1))
        fi
      done

      if [ "$additions" -gt 0 ]; then
        echo "Adding ${additions} secondary IPs to ${nic_name} in one bulk update..."
        if "${bulk_cmd[@]}"; then
          return 0
        fi
        echo "Bulk IP configuration update failed for ${nic_name}; falling back to sequential mode."
      else
        return 0
      fi
    fi
  fi

  for j in $(seq 1 "$MAX_SECONDARY_IPS"); do
    local sec_ip ipconfig_name
    sec_ip="${ip_prefix}.$((ip_base + j))"
    ipconfig_name="ipconfig$((j+1))"
    echo "Trying to add secondary IP: $sec_ip to $nic_name as $ipconfig_name"
    if ! az network nic ip-config create \
      --resource-group "$RESOURCE_GROUP" \
      --nic-name "$nic_name" \
      --name "$ipconfig_name" \
      --vnet-name "$VNET_NAME" \
      --subnet "$subnet_name" \
      --private-ip-address "$sec_ip" \
      --only-show-errors \
      --output none; then
      echo "Failed to add $sec_ip"
      echo "$sec_ip" >> "$fail_file"
    fi

    if [ "$IPCONFIG_DELAY_SEC" != "0" ]; then
      sleep "$IPCONFIG_DELAY_SEC"
    fi
  done
}

# After all subnets are ready, create NIC/VM and other resources in parallel
for (( i=0; i<INSTANCE_COUNT; i++ )); do
  (
    VM_NAME="${VM_NAME_PREFIX}${i}"
    NIC_NAME_1="${VM_NAME}NIC1"
    SUBNET_NAME_1="subnet${i}"
    IP_BASE=5
    PRIMARY_IP_1="10.1.$i.${IP_BASE}"

    # VM will use private IPs only - no public IP, no external access
    echo "VM ${VM_NAME} will use private IP only (${PRIMARY_IP_1}) - accessible via Bastion only"

    echo "CREATING FIRST NIC ${NIC_NAME_1} WITH PRIVATE IP ${PRIMARY_IP_1}..."
    az network nic create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$NIC_NAME_1" \
      --vnet-name "$VNET_NAME" \
      --subnet "$SUBNET_NAME_1" \
      --private-ip-address "$PRIMARY_IP_1" \
      --ip-forwarding true \
      --only-show-errors \
      --output none

    # Verify NIC creation
    for NIC_NAME in "$NIC_NAME_1"; do
      echo "Verifying NIC ${NIC_NAME} was created..."
      for verify_attempt in {1..10}; do
        if az network nic show --resource-group "$RESOURCE_GROUP" --name "$NIC_NAME" >/dev/null 2>&1; then
          echo "NIC ${NIC_NAME} verified successfully with IP forwarding enabled"
          break
        else
          echo "Attempt ${verify_attempt}/10: NIC ${NIC_NAME} not found, waiting..."
          if [ $verify_attempt -eq 10 ]; then
            echo "ERROR: NIC ${NIC_NAME} was not created successfully"
            exit 1
          fi
          sleep 5
        fi
      done
    done

    # Assign secondary IPs only to insX NIC1 (10.1.i.x).
    echo "Adding secondary IP configurations to ${NIC_NAME_1} (10.1.$i.x) only..."
    failed_ips=()
    FAIL_FILE_1="/tmp/ipcfg_failed_${NIC_NAME_1}.txt"

    add_secondary_ip_configs "$NIC_NAME_1" "$SUBNET_NAME_1" "10.1.$i" "$FAIL_FILE_1" "$IP_BASE"

    if [ -s "$FAIL_FILE_1" ]; then
      while IFS= read -r ip; do
        failed_ips+=("$ip")
      done < "$FAIL_FILE_1"
    fi
    rm -f "$FAIL_FILE_1"

    if [ ${#failed_ips[@]} -gt 0 ]; then
      echo "WARNING: Failed to add the following IPs: ${failed_ips[*]}"
    else
      echo "All secondary IPs added for ${NIC_NAME_1}"
    fi

    echo "CREATING VM ${VM_NAME} with single NIC..."
    
    # Verify SSH key exists before creating VM
    if [ ! -f "$AZURE_KEY_PUB_FILE" ]; then
        echo "ERROR: SSH public key not found at $AZURE_KEY_PUB_FILE"
        exit 1
    fi
    
    az vm create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$VM_NAME" \
      --nics "$NIC_NAME_1" \
      --image "$IMAGE" \
      "${SECURITY_ARGS[@]}" \
      --size "$VM_SIZE" \
      --location "$LOCATION" \
      --admin-username azureuser \
      --ssh-key-values "$AZURE_KEY_PUB_FILE" \
      --os-disk-name "${VM_NAME}-osdisk" \
      --os-disk-size-gb "$DISK_SIZE"

    # TBD: This doesn't work
    # Ensure boot diagnostics (standard boot log) are enabled for the VM
    # az vm update \
    #   --resource-group "$RESOURCE_GROUP" \
    #   --name "$VM_NAME" \
    #   --set diagnosticsProfile.bootDiagnostics.enabled=true

    # Enable IP forwarding on NIC
    for NIC_NAME in "$NIC_NAME_1"; do
      echo "Enabling IP forwarding on NIC ${NIC_NAME}..."
      az network nic update \
        --resource-group "$RESOURCE_GROUP" \
        --name "$NIC_NAME" \
        --ip-forwarding true
    done

    # Automatically sync local SSH public key to VM's authorized_keys
    az vm run-command invoke \
      --resource-group "$RESOURCE_GROUP" \
      --name "$VM_NAME" \
      --command-id RunShellScript \
      --scripts "mkdir -p /home/azureuser/.ssh; echo '$(cat ./azure-key.pub)' > /home/azureuser/.ssh/authorized_keys; chown -R azureuser:azureuser /home/azureuser/.ssh; chmod 600 /home/azureuser/.ssh/authorized_keys; echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf; sudo sysctl -p; echo 'Single NIC setup: eth0 (10.1.$i.x)'" \
      --output none

    # Wait for VM to be fully provisioned
    echo "Waiting for VM ${VM_NAME} to be fully provisioned..."
    for attempt in {1..30}; do
      VM_STATE=$(az vm get-instance-view \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --query "instanceView.statuses[?code=='PowerState/running']" \
        --output tsv 2>/dev/null)

      if [[ -n "$VM_STATE" ]]; then
        echo "VM ${VM_NAME} is running with private IP: ${PRIMARY_IP_1}"
        break
      fi

      echo "Attempt ${attempt}/30: VM ${VM_NAME} not ready yet, waiting..."
      if [ $attempt -eq 30 ]; then
        echo "ERROR: VM ${VM_NAME} failed to start properly"
        exit 1
      fi
      sleep 10
    done

  ################################################################################
    # PRE-COPY LOCAL SCRIPTS DIRECTORY TO REMOTE MACHINE FOR LATER USE
    ################################################################################
    echo "COPYING LOCAL SCRIPTS FOLDER TO REMOTE VM ${VM_NAME}"

    # Use run-command for reliable file transfer
    echo "Using Azure run-command to transfer scripts..."
    tar -czf /tmp/scripts_${VM_NAME}.tar.gz -C . instance_scripts/
    scripts_b64=$(base64 < /tmp/scripts_${VM_NAME}.tar.gz)
    az vm run-command invoke \
      --resource-group "$RESOURCE_GROUP" \
      --name "$VM_NAME" \
      --command-id RunShellScript \
      --scripts "echo '${scripts_b64}' | base64 -d > /tmp/scripts.tar.gz && cd /home/azureuser && tar -xzf /tmp/scripts.tar.gz && chown -R azureuser:azureuser instance_scripts/ && rm /tmp/scripts.tar.gz" \
      --output none
    rm -f /tmp/scripts_${VM_NAME}.tar.gz

    ################################################################################
    # STEP 4: REMOTE BUILD KERNEL & CONFIGURATION VIA AZURE VM EXTENSION
    ################################################################################
    INSTANCE_ID=${i}
    echo "STARTING KERNEL BUILD AND CONFIGURATION ON ${VM_NAME}"

    # Execute build_instance.sh using VM extension
    echo "Executing build_instance.sh on ${VM_NAME} using VM extension..."
    az vm extension set \
      --resource-group "$RESOURCE_GROUP" \
      --vm-name "$VM_NAME" \
      --name CustomScript \
      --publisher Microsoft.Azure.Extensions \
      --settings "{\"commandToExecute\": \"cd /home/azureuser && bash ./instance_scripts/build_instance.sh ${INSTANCE_ID} ${INSTANCE_COUNT}\"}" \
      --no-wait

  ) &

done

wait || echo "Some background jobs failed or were killed."

################################################################################
# Step 6: All Azure VM creation and configuration commands executed.
################################################################################
echo "All Azure VM creation and configuration commands executed."
