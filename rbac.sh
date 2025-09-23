#!/bin/bash
################################################################################
# Step 5: Assign RBAC roles to Entra ID group for all created resources
################################################################################
echo "Assigning RBAC roles to Entra ID group for all created resources..."

# Inputs
RESOURCE_GROUP="chronos-exp"
GROUP_OBJECT_ID="FILL IN" # chronos-exp
ROLE="Reader"

# Assign Reader role to all VMs
for vm in $(az vm list -g "$RESOURCE_GROUP" --query "[].id" -o tsv); do
    echo "Assigning Reader role to VM: $vm"
    az role assignment create --assignee "$GROUP_OBJECT_ID" --role "$ROLE" --scope "$vm"
done

# Assign Reader role to NICs with private IPs of VMs
for nic_id in $(az network nic list -g "$RESOURCE_GROUP" --query "[?ipConfigurations[0].privateIpAddress!=null].id" -o tsv); do
    echo "Assigning Reader role to NIC: $nic_id"
    az role assignment create --assignee "$GROUP_OBJECT_ID" --role "$ROLE" --scope "$nic_id"
done

# Assign Reader role to Azure Bastion resources
for bastion_id in $(az network bastion list -g "$RESOURCE_GROUP" --query "[].id" -o tsv); do
    echo "Assigning Reader role to Bastion: $bastion_id"
    az role assignment create --assignee "$GROUP_OBJECT_ID" --role "$ROLE" --scope "$bastion_id"
done

# Assign Reader role to VNETs of VMs (including peered networks)
for vm in $(az vm list -g "$RESOURCE_GROUP" --query "[].name" -o tsv); do
    nic_id=$(az vm show -g "$RESOURCE_GROUP" -n "$vm" --query "networkProfile.networkInterfaces[0].id" -o tsv)
    vnet_id=$(az network nic show --ids "$nic_id" --query "ipConfigurations[0].subnet.id" -o tsv | awk -F'/subnets/' '{print $1}')
    echo "Assigning Reader role to VNET: $vnet_id"
    az role assignment create --assignee "$GROUP_OBJECT_ID" --role "$ROLE" --scope "$vnet_id"
done

echo "RBAC assignments completed."

