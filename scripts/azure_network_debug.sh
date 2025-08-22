#!/bin/bash

# Azure Network Debugging Script

echo "=== Azure Network Configuration Debugging ==="

# Check Azure CLI version and login status
echo "1. Azure CLI Status:"
az --version | head -1
az account show --query "name" -o tsv 2>/dev/null || echo "Not logged into Azure CLI"

# Check resource group and location
RESOURCE_GROUP="chronos-test"
LOCATION="uksouth"

echo "2. Resource Group Status:"
az group show --name "$RESOURCE_GROUP" --query "provisioningState" -o tsv 2>/dev/null || echo "Resource group not found"

# Check VNet configuration
echo "3. VNet Configuration:"
VNET_NAME="myVnet"
az network vnet show --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" --query "{name:name,addressSpace:addressSpace.addressPrefixes,provisioningState:provisioningState}" -o table 2>/dev/null || echo "VNet not found"

# Check subnets
echo "4. Subnet Configuration:"
az network vnet subnet list --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --query "[].{name:name,addressPrefix:addressPrefix,provisioningState:provisioningState}" -o table 2>/dev/null || echo "No subnets found"

# Check public IPs
echo "5. Public IP Status:"
az network public-ip list --resource-group "$RESOURCE_GROUP" --query "[].{name:name,ipAddress:ipAddress,allocationMethod:publicIPAllocationMethod,provisioningState:provisioningState}" -o table 2>/dev/null || echo "No public IPs found"

# Check NSGs
echo "6. Network Security Groups:"
az network nsg list --resource-group "$RESOURCE_GROUP" --query "[].{name:name,provisioningState:provisioningState}" -o table 2>/dev/null || echo "No NSGs found"

# Check NICs
echo "7. Network Interfaces:"
az network nic list --resource-group "$RESOURCE_GROUP" --query "[].{name:name,provisioningState:provisioningState,ipForwarding:enableIPForwarding}" -o table 2>/dev/null || echo "No NICs found"

# Check VMs
echo "8. Virtual Machines:"
az vm list --resource-group "$RESOURCE_GROUP" --query "[].{name:name,provisioningState:provisioningState,powerState:powerState}" -o table 2>/dev/null || echo "No VMs found"

# Function to fix common Azure CLI command issues
echo "9. Testing Azure CLI Commands:"

# Test public IP creation with correct syntax
echo "Testing public IP creation syntax..."
cat << 'EOF'
# Correct syntax:
az network public-ip create \
  --resource-group "chronos-test" \
  --name "test-ip" \
  --location "uksouth" \
  --allocation-method Static \
  --sku Standard

# Common mistakes to avoid:
# - Using 'network.public-ip' instead of 'network public-ip'
# - Missing required parameters
# - Wrong parameter names
EOF

# Check Azure resource limits
echo "10. Checking Azure Quotas (if available):"
az vm list-usage --location "$LOCATION" --query "[?name.value=='cores'].{limit:limit,currentValue:currentValue}" -o table 2>/dev/null || echo "Cannot check quotas"

echo "=== Network Debugging Complete ==="


