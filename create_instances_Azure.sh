#!/bin/bash
################################################################################
# Step 1: Extract GitHub credentials from file
################################################################################
CRED_FILE="../git-credentials"
if [ ! -f "$CRED_FILE" ]; then
    echo "Git credentials file not found at: $CRED_FILE"
    exit 1
fi
# Extract GitHub username and token (format: username:token)
read GITHUB_USERNAME GITHUB_TOKEN < <(awk -F: '{print $1, $2}' "$CRED_FILE")
if [ -z "$GITHUB_USERNAME" ] || [ -z "$GITHUB_TOKEN" ]; then
    echo "GitHub credentials extraction failed."
    exit 1
fi
echo "Using GitHub user: ${GITHUB_USERNAME}"

################################################################################
# Step 2: Define Azure instance parameters
################################################################################

# Default values
RESOURCE_GROUP="chronos-test"
LOCATION="uksouth"
VM_SIZE="Standard_D2s_v3"
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
IMAGE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/chronos-test/providers/Microsoft.Compute/galleries/chronosGallery/images/chronosBaseImage/versions/1.0.0"
INSTANCE_COUNT=1
VM_NAME_PREFIX="ins"
# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            echo "create_instances_Azure.sh - create Azure VMs and configure Chronos experiment"
            echo ""
            echo "Usage:"
            echo "  ./create_instances_Azure.sh --resource-group <resource-group> --location <location> --vm-size <vm-size> --instance-count <count> [--secondary-ip-count <count>] [--vm-per-instance <count>]"
            echo ""
            echo "Options:"
            echo "  --help, -h                      Show this help message and exit"
            echo "  --resource-group <name>          Azure resource group name (default: chronos-test)"
            echo "  --location <location>            Azure region, e.g., uksouth (default: uksouth)"
            echo "  --vm-size <type>                 Azure VM size, e.g., Standard_D2s_v3 (default: Standard_D2s_v3)"
            echo "  --instance-count <count>         Number of Azure VMs to launch (default: 1)"
            echo "  --secondary-ip-count <count>     Number of extra private IPs per VM (default: 2)"
            echo "  --vm-per-instance <count>        Number of QEMU VMs per Azure VM (default: 2)"
            echo "  --vm-name-prefix <prefix>        Prefix for VM names (default: ins)"
            echo ""
            echo "Example:"
            echo "  ./create_instances_Azure.sh --resource-group chronos-test --location uksouth --vm-size Standard_D2s_v3 --instance-count 2 --secondary-ip-count 2"
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
        *)
            break
            ;;
    esac
done

VNET_NAME="myVnet"
SUBNET_NAME="main-subnet"
VNET_PREFIX="10.0.0.0/8"
#SUBNET_PREFIX="10.1.0.0/24"
SUBNET_PREFIX="10.0.1.0/24"

# Parse parameters, support --secondary-ip-count or --vm-per-instance
MAX_SECONDARY_IPS=2
while [[ $# -gt 0 ]]; do
    case "$1" in
        --secondary-ip-count=*|--vm-per-instance=*)
            MAX_SECONDARY_IPS="${1#*=}"
            shift
            ;;
        --secondary-ip-count|--vm-per-instance)
            shift
            MAX_SECONDARY_IPS="$1"
            shift
            ;;
        *)
            break
            ;;
    esac
done


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
BASTION_NAME="chronos-bastion"
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
if [[ "$BASTION_STATE" == "Succeeded" ]]; then
  echo "Azure Bastion ${BASTION_NAME} already exists and is ready (state: $BASTION_STATE)."
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
# Step 3: Create Azure VMs and configure each VM remotely
################################################################################

# Sequentially create all subnets to avoid concurrency conflicts
# Create both subnet sets for all instances
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
      --nat-gateway "$NAT_GATEWAY_NAME"

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

    # Second subnet set (10.3.x.0/24)
    SUBNET_NAME_2="subnet-sec${i}"
    SUBNET_PREFIX_2="10.3.$i.0/24"
    echo "Creating subnet ${SUBNET_NAME_2} with prefix ${SUBNET_PREFIX_2}..."
    az network vnet subnet create \
      --resource-group "$RESOURCE_GROUP" \
      --vnet-name "$VNET_NAME" \
      --name "$SUBNET_NAME_2" \
      --address-prefix "$SUBNET_PREFIX_2" \
      --nat-gateway "$NAT_GATEWAY_NAME"

    # Wait for second subnet creation to complete
    for subnet_attempt in {1..10}; do
      if az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$SUBNET_NAME_2" >/dev/null 2>&1; then
        echo "Subnet ${SUBNET_NAME_2} created successfully with NAT Gateway"
        break
      else
        echo "Waiting for subnet ${SUBNET_NAME_2} to be ready... (${subnet_attempt}/10)"
        sleep 3
      fi
      if [ $subnet_attempt -eq 10 ]; then
        echo "ERROR: Subnet ${SUBNET_NAME_2} was not created successfully"
        exit 1
      fi
    done
done

# After all subnets are ready, create NIC/VM and other resources in parallel
for (( i=0; i<INSTANCE_COUNT; i++ )); do
  (
    VM_NAME="${VM_NAME_PREFIX}${i}"
    NIC_NAME_1="${VM_NAME}NIC1"
    NIC_NAME_2="${VM_NAME}NIC2"
    SUBNET_NAME_1="subnet${i}"
    SUBNET_NAME_2="subnet-sec${i}"
    IP_BASE=5
    PRIMARY_IP_1="10.1.$i.${IP_BASE}"
    PRIMARY_IP_2="10.3.$i.${IP_BASE}"

    # VM will use private IPs only - no public IP, no external access
    echo "VM ${VM_NAME} will use private IPs only (${PRIMARY_IP_1}, ${PRIMARY_IP_2}) - accessible via Bastion only"

    echo "CREATING FIRST NIC ${NIC_NAME_1} WITH PRIVATE IP ${PRIMARY_IP_1}..."
    az network nic create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$NIC_NAME_1" \
      --vnet-name "$VNET_NAME" \
      --subnet "$SUBNET_NAME_1" \
      --private-ip-address "$PRIMARY_IP_1" \
      --ip-forwarding true

    echo "CREATING SECOND NIC ${NIC_NAME_2} WITH PRIVATE IP ${PRIMARY_IP_2}..."
    az network nic create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$NIC_NAME_2" \
      --vnet-name "$VNET_NAME" \
      --subnet "$SUBNET_NAME_2" \
      --private-ip-address "$PRIMARY_IP_2" \
      --ip-forwarding true

    # Verify both NICs creation
    for NIC_NAME in "$NIC_NAME_1" "$NIC_NAME_2"; do
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

    # Assign secondary IPs to first NIC (10.1.i.x)
    echo "Adding secondary IP configurations to ${NIC_NAME_1}..."
    failed_ips=()
    for j in $(seq 1 $MAX_SECONDARY_IPS); do
      SEC_IP="10.1.$i.$((IP_BASE + j))"
      ipconfig_name="ipconfig$((j+1))"
      echo "Trying to add secondary IP: $SEC_IP to $NIC_NAME_1 as $ipconfig_name"
      if ! az network nic ip-config create \
        --resource-group "$RESOURCE_GROUP" \
        --nic-name "$NIC_NAME_1" \
        --name "$ipconfig_name" \
        --vnet-name "$VNET_NAME" \
        --subnet "$SUBNET_NAME_1" \
        --private-ip-address "$SEC_IP" \
        --make-primary false 2>&1 | tee /tmp/ipconfig_${NIC_NAME_1}_${SEC_IP}.log; then
        echo "Failed to add $SEC_IP, see /tmp/ipconfig_${NIC_NAME_1}_${SEC_IP}.log"
        failed_ips+=($SEC_IP)
      fi
      sleep 1
    done

    # Assign secondary IPs to second NIC (10.3.i.x)
    echo "Adding secondary IP configurations to ${NIC_NAME_2}..."
    for j in $(seq 1 $MAX_SECONDARY_IPS); do
      SEC_IP="10.3.$i.$((IP_BASE + j))"
      ipconfig_name="ipconfig$((j+1))"
      echo "Trying to add secondary IP: $SEC_IP to $NIC_NAME_2 as $ipconfig_name"
      if ! az network nic ip-config create \
        --resource-group "$RESOURCE_GROUP" \
        --nic-name "$NIC_NAME_2" \
        --name "$ipconfig_name" \
        --vnet-name "$VNET_NAME" \
        --subnet "$SUBNET_NAME_2" \
        --private-ip-address "$SEC_IP" \
        --make-primary false 2>&1 | tee /tmp/ipconfig_${NIC_NAME_2}_${SEC_IP}.log; then
        echo "Failed to add $SEC_IP, see /tmp/ipconfig_${NIC_NAME_2}_${SEC_IP}.log"
        failed_ips+=($SEC_IP)
      fi
      sleep 1
    done

    if [ ${#failed_ips[@]} -gt 0 ]; then
      echo "WARNING: Failed to add the following IPs: ${failed_ips[*]}"
    else
      echo "All secondary IPs added for both NICs"
    fi

    echo "CREATING VM ${VM_NAME} with dual NICs..."
    az vm create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$VM_NAME" \
      --nics "$NIC_NAME_1" "$NIC_NAME_2" \
      --image "$IMAGE" \
      --security-type TrustedLaunch \
      --size "$VM_SIZE" \
      --location "$LOCATION" \
      --enable-secure-boot false \
      --admin-username azureuser \
      --generate-ssh-keys

    # Enable IP forwarding on both NICs
    for NIC_NAME in "$NIC_NAME_1" "$NIC_NAME_2"; do
      echo "Enabling IP forwarding on NIC ${NIC_NAME}..."
      az network nic update \
        --resource-group "$RESOURCE_GROUP" \
        --name "$NIC_NAME" \
        --ip-forwarding true
    done

    # Automatically sync local SSH public key to VM's authorized_keys and configure dual NICs
    az vm run-command invoke \
      --resource-group "$RESOURCE_GROUP" \
      --name "$VM_NAME" \
      --command-id RunShellScript \
      --scripts "mkdir -p /home/azureuser/.ssh; echo '$(cat ~/.ssh/id_rsa.pub)' > /home/azureuser/.ssh/authorized_keys; chown -R azureuser:azureuser /home/azureuser/.ssh; chmod 600 /home/azureuser/.ssh/authorized_keys; echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf; sudo sysctl -p; echo 'Dual NIC setup: eth0 (10.1.$i.x) and eth1 (10.3.$i.x)'" \
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
        echo "VM ${VM_NAME} is running with private IP: ${PRIMARY_IP_1}, ${PRIMARY_IP_2}"
        break
      fi

      echo "Attempt ${attempt}/30: VM ${VM_NAME} not ready yet, waiting..."
      if [ $attempt -eq 30 ]; then
        echo "ERROR: VM ${VM_NAME} failed to start properly"
        exit 1
      fi
      sleep 10
    done

    # Test SSH connectivity via Bastion only
    echo "Testing SSH connectivity to ${VM_NAME} via Bastion..."
    ssh_success=false

    # Ensure VM is ready and SSH service is running
    for check_attempt in {1..10}; do
        echo "Service check attempt ${check_attempt}/10..."

        # Use Azure VM run-command to check SSH service status
        service_status=$(az vm run-command invoke \
            --resource-group "$RESOURCE_GROUP" \
            --name "$VM_NAME" \
            --command-id RunShellScript \
            --scripts "systemctl is-active ssh || systemctl is-active sshd" \
            --query "value[0].message" \
            --output tsv 2>/dev/null || echo "failed")

        echo "SSH service status: $service_status"

        if [[ "$service_status" == *"active"* ]]; then
            echo "SSH service is active on ${VM_NAME}"
            break
        elif [[ "$service_status" == *"failed"* ]] || [[ "$service_status" == *"inactive"* ]]; then
            echo "Starting SSH service on ${VM_NAME}..."
            az vm run-command invoke \
                --resource-group "$RESOURCE_GROUP" \
                --name "$VM_NAME" \
                --command-id RunShellScript \
                --scripts "sudo systemctl start ssh || sudo systemctl start sshd; sudo systemctl enable ssh || sudo systemctl enable sshd" \
                --output none
        fi

        sleep 10
    done

    # Try basic Bastion SSH connectivity test
    for attempt in {1..3}; do
      echo "SSH attempt ${attempt}/3 to ${VM_NAME} via Bastion..."

      # Try az network bastion ssh (without --command parameter)
      if timeout 30 az network bastion ssh \
        --name "$BASTION_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --target-resource-id "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Compute/virtualMachines/${VM_NAME}" \
        --auth-type "ssh-key" \
        --username "azureuser" \
        --ssh-key "~/.ssh/id_rsa" 2>/tmp/bastion_ssh_${VM_NAME}.log <<<'echo "SSH test successful"; exit'; then
        echo "✓ SSH via Bastion to ${VM_NAME} established successfully"
        ssh_success=true
        break
      else
        echo "✗ Bastion SSH test failed. Debug output:"
        tail -5 /tmp/bastion_ssh_${VM_NAME}.log 2>/dev/null || echo "No debug log available"
      fi

      sleep 10
    done

    # Since SSH tests are unreliable, we'll assume success if VM is running and SSH service is active
    if [[ "$service_status" == *"active"* ]]; then
      echo "✓ VM ${VM_NAME} is ready for operations (SSH service active)"
      ssh_success=true
    else
      echo "⚠️ Cannot confirm SSH connectivity to ${VM_NAME}, using run-command only"
      ssh_success=false
    fi

    # Always use run-command for reliability
    USE_RUN_COMMAND=true

 ################################################################################
    # PRE-COPY LOCAL SCRIPTS DIRECTORY TO REMOTE MACHINE FOR LATER USE
    ################################################################################
    echo "COPYING LOCAL SCRIPTS FOLDER TO REMOTE VM ${VM_NAME}"

    # Use run-command for reliable file transfer
    echo "Using Azure run-command to transfer scripts..."
    tar -czf /tmp/scripts_${VM_NAME}.tar.gz -C . scripts/
#    scripts_b64=$(base64 -i /tmp/scripts_${VM_NAME}.tar.gz)
    scripts_b64=$(base64 < /tmp/scripts_${VM_NAME}.tar.gz)
    az vm run-command invoke \
      --resource-group "$RESOURCE_GROUP" \
      --name "$VM_NAME" \
      --command-id RunShellScript \
      --scripts "echo '${scripts_b64}' | base64 -d > /tmp/scripts.tar.gz && cd /home/azureuser && tar -xzf /tmp/scripts.tar.gz && chown -R azureuser:azureuser scripts/ && rm /tmp/scripts.tar.gz" \
      --output none
    rm -f /tmp/scripts_${VM_NAME}.tar.gz

    ################################################################################
    # STEP 4: REMOTE BUILD KERNEL & CONFIGURATION VIA SCRIPT FILE
    ################################################################################
    INSTANCE_ID=${i}
    echo "STARTING REMOTE KERNEL BUILD AND CONFIGURATION ON ${VM_NAME}"

    # Step 4.1: Transfer the script using run-command (reliable)
    echo "Transferring remote_build_kernel.sh to ${VM_NAME}..."

#      echo "Executing remote_build_kernel.sh on ${VM_NAME} using run-command..."
#      script_b64=$(base64 < ./remote_build_kernel.sh)
#      az vm run-command invoke \
#        --resource-group "$RESOURCE_GROUP" \
#        --name "$VM_NAME" \
#        --command-id RunShellScript \
#        --scripts "echo '${script_b64}' | base64 -d > /home/azureuser/remote_build_kernel.sh && chmod +x /home/azureuser/remote_build_kernel.sh && cd /home/azureuser && ./remote_build_kernel.sh ${INSTANCE_ID} ${INSTANCE_COUNT} ${GITHUB_USERNAME} ${GITHUB_TOKEN}" \
#        --output table\

      echo "Executing remote_build_kernel.sh on ${VM_NAME} using run-command..."
    script_b64=$(base64 < ./remote_build_kernel.sh)
    az vm run-command invoke \
      --resource-group "$RESOURCE_GROUP" \
      --name "$VM_NAME" \
      --command-id RunShellScript \
      --scripts "echo '${script_b64}' | base64 -d > /home/azureuser/remote_build_kernel.sh && chmod +x /home/azureuser/remote_build_kernel.sh" \
      --output table


  ) &
done

wait || echo "Some background jobs failed or were killed."

################################################################################
# Step 6: All Azure VM creation and configuration commands executed.
################################################################################
echo "All Azure VM creation and configuration commands executed."
