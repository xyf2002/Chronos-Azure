#!/bin/bash
# Usage: delete_chronos_resources.sh --resource-group <RESOURCE_GROUP>
# This script deletes all resources in the specified Azure resource group
# except for base image, image definition, and gallery.
# If --resource-group is not specified, it defaults to 'chronos-test'.

# Parse --resource-group argument
RESOURCE_GROUP="chronos-test"
SKIP_BASTION=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      echo "delete_chronos_resources.sh - delete all Chronos experiment resources in Azure except base image and gallery"
      echo ""
      echo "Usage:"
      echo "  ./delete_chronos_resources.sh --resource-group <resource-group> [--skip-bastion]"
      echo ""
      echo "Options:"
      echo "  --help, -h                  Show this help message and exit"
      echo "  --resource-group <name>     Azure resource group name (default: chronos-test)"
      echo "  --skip-bastion              Skip bastion host deletion (useful if it's stuck)"
      echo ""
      echo "Example:"
      echo "  ./delete_chronos_resources.sh --resource-group chronos-test"
      echo "  ./delete_chronos_resources.sh --resource-group chronos-test --skip-bastion"
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
    --skip-bastion)
      SKIP_BASTION=true
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# Delete all resources in the specified resource group except base image, image definition, and gallery

# Get the gallery name (assume only one gallery, or adjust as needed)
GALLERY_NAME=$(az sig list --resource-group "$RESOURCE_GROUP" --query "[0].name" -o tsv)
GALLERY_ID=$(az sig show --resource-group "$RESOURCE_GROUP" --gallery-name "$GALLERY_NAME" --query "id" -o tsv 2>/dev/null)

echo "Listing existing image gallery, image definitions, and base image..."
IMAGE_DEF_IDS=$(az sig image-definition list --resource-group "$RESOURCE_GROUP" --gallery-name "$GALLERY_NAME" --query "[].id" -o tsv 2>/dev/null)
BASE_IMAGE_IDS=$(az sig image-version list --resource-group "$RESOURCE_GROUP" --gallery-name "$GALLERY_NAME" --gallery-image-definition chronosBaseImage --query "[].id" -o tsv 2>/dev/null)

# Collect resource IDs to keep (gallery, image definitions, base images)
KEEP_IDS=()
if [ -n "$GALLERY_ID" ]; then
  KEEP_IDS+=("$GALLERY_ID")
fi
for id in $IMAGE_DEF_IDS $BASE_IMAGE_IDS; do
  KEEP_IDS+=("$id")
done

echo "Finding all resources..."
ALL_RES_IDS=$(az resource list --resource-group "$RESOURCE_GROUP" --query "[].id" -o tsv)

VM_IDS=()
NIC_IDS=()
NSG_IDS=()
PIP_IDS=()
NATGW_IDS=()
VNET_IDS=()
DISK_IDS=()
LB_IDS=()
BASTION_IDS=()
OTHER_IDS=()

for id in $ALL_RES_IDS; do
  if [[ "$id" == *"/virtualMachines/"* ]]; then
    VM_IDS+=("$id")
  elif [[ "$id" == *"/networkInterfaces/"* ]]; then
    NIC_IDS+=("$id")
  elif [[ "$id" == *"/networkSecurityGroups/"* ]]; then
    NSG_IDS+=("$id")
  elif [[ "$id" == *"/publicIPAddresses/"* ]]; then
    PIP_IDS+=("$id")
  elif [[ "$id" == *"/natGateways/"* ]]; then
    NATGW_IDS+=("$id")
  elif [[ "$id" == *"/virtualNetworks/"* ]]; then
    VNET_IDS+=("$id")
  elif [[ "$id" == *"/disks/"* ]]; then
    DISK_IDS+=("$id")
  elif [[ "$id" == *"/loadBalancers/"* ]]; then
    LB_IDS+=("$id")
  elif [[ "$id" == *"/bastionHosts/"* ]]; then
    BASTION_IDS+=("$id")
  else
    OTHER_IDS+=("$id")
  fi
done


filter_keep() {
  local arr=("$@")
  local filtered=()
  for id in "${arr[@]}"; do
    skip=false
    for keep in "${KEEP_IDS[@]}"; do
      if [[ "$id" == "$keep" ]]; then
        skip=true
        break
      fi
    done
    if [ "$skip" = false ]; then
      filtered+=("$id")
    fi
  done
  echo "${filtered[@]}"
}

VM_IDS=($(filter_keep "${VM_IDS[@]}"))
NIC_IDS=($(filter_keep "${NIC_IDS[@]}"))
NSG_IDS=($(filter_keep "${NSG_IDS[@]}"))
PIP_IDS=($(filter_keep "${PIP_IDS[@]}"))
NATGW_IDS=($(filter_keep "${NATGW_IDS[@]}"))
VNET_IDS=($(filter_keep "${VNET_IDS[@]}"))
DISK_IDS=($(filter_keep "${DISK_IDS[@]}"))
LB_IDS=($(filter_keep "${LB_IDS[@]}"))
BASTION_IDS=($(filter_keep "${BASTION_IDS[@]}"))
OTHER_IDS=($(filter_keep "${OTHER_IDS[@]}"))

# Apply --skip-bastion flag
if [ "$SKIP_BASTION" = true ]; then
  echo "Skipping bastion resources as requested..."
  BASTION_IDS=()
  # Also remove bastion-related PIPs
  FILTERED_PIP_IDS=()
  for id in "${PIP_IDS[@]}"; do
    if [[ "$id" != *"bastion"* ]]; then
      FILTERED_PIP_IDS+=("$id")
    fi
  done
  PIP_IDS=("${FILTERED_PIP_IDS[@]}")
fi

echo "The following resources will be deleted in dependency order:"
echo "=== Layer 1: Virtual Machines ==="
for id in "${VM_IDS[@]}"; do echo "$id"; done
echo "=== Layer 2: Bastion Hosts ==="
for id in "${BASTION_IDS[@]}"; do echo "$id"; done
echo "=== Layer 3: Load Balancers ==="
for id in "${LB_IDS[@]}"; do echo "$id"; done
echo "=== Layer 4: Network Interfaces ==="
for id in "${NIC_IDS[@]}"; do echo "$id"; done
echo "=== Layer 5: Disks ==="
for id in "${DISK_IDS[@]}"; do echo "$id"; done
echo "=== Layer 6: NAT Gateways ==="
for id in "${NATGW_IDS[@]}"; do echo "$id"; done
echo "=== Layer 7: Network Security Groups ==="
for id in "${NSG_IDS[@]}"; do echo "$id"; done
echo "=== Layer 8: Public IP Addresses ==="
for id in "${PIP_IDS[@]}"; do echo "$id"; done
echo "=== Layer 9: Virtual Networks ==="
for id in "${VNET_IDS[@]}"; do echo "$id"; done
echo "=== Layer 10: Other Resources ==="
for id in "${OTHER_IDS[@]}"; do echo "$id"; done

read -p "Confirm deletion of the above resources? (y/N): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Cancelled"
  exit 0
fi

# Enhanced deletion function with dependency handling
delete_resource_with_retry() {
  local resource_id="$1"
  local resource_type="$2"
  local max_retries=3
  local retry_count=0

  # Special handling for bastion hosts - they take longer
  if [[ "$resource_type" == "bastion" ]]; then
    max_retries=5
    echo "Deleting bastion host $resource_id (this may take several minutes)..."
  fi

  while [ $retry_count -lt $max_retries ]; do
    if [[ "$resource_type" != "bastion" ]]; then
      echo "Deleting $resource_id (attempt $((retry_count + 1))/$max_retries)..."
    fi

    if az resource delete --ids "$resource_id" --verbose 2>/dev/null; then
      echo "✓ Successfully deleted $resource_id"
      return 0
    else
      retry_count=$((retry_count + 1))
      if [ $retry_count -lt $max_retries ]; then
        if [[ "$resource_type" == "bastion" ]]; then
          echo "⚠ Bastion deletion attempt $retry_count failed, waiting 60 seconds before retry..."
          sleep 60
        else
          echo "⚠ Failed to delete $resource_id, waiting 15 seconds before retry..."
          sleep 15
        fi
      else
        echo "✗ Failed to delete $resource_id after $max_retries attempts"
        return 1
      fi
    fi
  done
}

# Function to wait for resource to be deleted
wait_for_deletion() {
  local resource_id="$1"
  local max_wait=30
  local wait_count=0

  while [ $wait_count -lt $max_wait ]; do
    if ! az resource show --ids "$resource_id" >/dev/null 2>&1; then
      return 0
    fi
    wait_count=$((wait_count + 1))
    echo "Waiting for $resource_id to be deleted... ($wait_count/$max_wait)"
    sleep 10
  done
  return 1
}

# Enhanced resource deletion in dependency order
FAILED_DELETIONS=()

echo "=== Starting Layer 1: Virtual Machines ==="
for id in "${VM_IDS[@]}"; do
  delete_resource_with_retry "$id" "vm" || FAILED_DELETIONS+=("$id")
done

# Wait a bit for VMs to fully deallocate
if [ ${#VM_IDS[@]} -gt 0 ]; then
  echo "Waiting 30 seconds for VMs to deallocate..."
  sleep 30
fi

echo "=== Starting Layer 2: Bastion Hosts ==="
for id in "${BASTION_IDS[@]}"; do
  delete_resource_with_retry "$id" "bastion" || FAILED_DELETIONS+=("$id")
done

# Wait for bastion to be fully deleted before proceeding
if [ ${#BASTION_IDS[@]} -gt 0 ]; then
  echo "Waiting 60 seconds for bastion hosts to be fully deleted..."
  sleep 60
fi

echo "=== Starting Layer 3: Load Balancers ==="
for id in "${LB_IDS[@]}"; do
  delete_resource_with_retry "$id" "loadbalancer" || FAILED_DELETIONS+=("$id")
done

echo "=== Starting Layer 4: Network Interfaces ==="
for id in "${NIC_IDS[@]}"; do
  delete_resource_with_retry "$id" "nic" || FAILED_DELETIONS+=("$id")
done

echo "=== Starting Layer 5: Disks ==="
for id in "${DISK_IDS[@]}"; do
  delete_resource_with_retry "$id" "disk" || FAILED_DELETIONS+=("$id")
done

echo "=== Starting Layer 6: NAT Gateways ==="
for id in "${NATGW_IDS[@]}"; do
  echo "Pre-processing NAT Gateway: $id"
  # Disassociate public IPs first
  PIP_IDS_ATTACHED=$(az network nat gateway show --ids "$id" --query "publicIpAddresses[].id" -o tsv 2>/dev/null)
  for pip in $PIP_IDS_ATTACHED; do
    echo "Disassociating $pip from NAT Gateway..."
    az network nat gateway update --ids "$id" --remove publicIpAddresses "$pip" 2>/dev/null || true
  done

  # Disassociate from subnets
  SUBNET_IDS_ATTACHED=$(az network vnet subnet list --resource-group "$RESOURCE_GROUP" --vnet-name "*" --query "[?natGateway.id=='$id'].id" -o tsv 2>/dev/null)
  for subnet in $SUBNET_IDS_ATTACHED; do
    echo "Disassociating NAT Gateway from subnet..."
    az network vnet subnet update --ids "$subnet" --remove natGateway 2>/dev/null || true
  done

  sleep 5  # Wait for disassociation
  delete_resource_with_retry "$id" "natgateway" || FAILED_DELETIONS+=("$id")
done

echo "=== Starting Layer 7: Network Security Groups ==="
for id in "${NSG_IDS[@]}"; do
  delete_resource_with_retry "$id" "nsg" || FAILED_DELETIONS+=("$id")
done

echo "=== Starting Layer 8: Public IP Addresses ==="
for id in "${PIP_IDS[@]}"; do
  delete_resource_with_retry "$id" "pip" || FAILED_DELETIONS+=("$id")
done

echo "=== Starting Layer 9: Virtual Networks ==="
for id in "${VNET_IDS[@]}"; do
  delete_resource_with_retry "$id" "vnet" || FAILED_DELETIONS+=("$id")
done

echo "=== Starting Layer 10: Other Resources ==="
for id in "${OTHER_IDS[@]}"; do
  delete_resource_with_retry "$id" "other" || FAILED_DELETIONS+=("$id")
done

echo "Cleanup completed."
echo ""

if [ ${#FAILED_DELETIONS[@]} -gt 0 ]; then
  echo "⚠ Warning: The following resources failed to delete:"
  for failed in "${FAILED_DELETIONS[@]}"; do
    echo "  - $failed"
  done
  echo ""
  echo "You may need to:"
  echo "1. Wait a few minutes and run the script again"
  echo "2. Check for remaining dependencies in the Azure portal"
  echo "3. Delete these resources manually"
else
  echo "✓ All resources deleted successfully!"
fi

