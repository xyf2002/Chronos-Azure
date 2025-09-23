# Inputs
$resourceGroup = "chronos-expr"
$groupObjectId = "FILL IN"
$role = "Reader"
$keyVaultReaderRole = "Key Vault Secrets User"  # Allows reading secrets


# Assign Reader role to the resource group
$rgId = az group show --name $resourceGroup --query "id" -o tsv
Write-Host "Assigning Reader role to Resource Group: $rgId"
az role assignment create --assignee $groupObjectId --role $role --scope $rgId

# Assign Reader role to all VMs
$vmList = az vm list -g $resourceGroup --query "[].id" -o tsv
foreach ($vmId in $vmList) {
    Write-Host "Assigning Reader and Login roles to VM: $vmId"
    az role assignment create --assignee $groupObjectId --role $role --scope $vmId
    az role assignment create --assignee $groupObjectId --role "Virtual Machine User Login" --scope $vmId
}

# Assign Reader role to NICs with private IPs
$nicList = az network nic list -g $resourceGroup --query "[?ipConfigurations[0].privateIpAddress!=null].id" -o tsv
foreach ($nicId in $nicList) {
    Write-Host "Assigning Reader role to NIC: $nicId"
    az role assignment create --assignee $groupObjectId --role $role --scope $nicId
}

# Assign Reader role to Azure Bastion resources
$bastionList = az network bastion list -g $resourceGroup --query "[].id" -o tsv
foreach ($bastionId in $bastionList) {
    Write-Host "Assigning Reader role to Bastion: $bastionId"
    az role assignment create --assignee $groupObjectId --role $role --scope $bastionId
}

# Assign Reader role to VNETs of VMs
$vmNames = az vm list -g $resourceGroup --query "[].name" -o tsv
foreach ($vmName in $vmNames) {
    $nicId = az vm show -g $resourceGroup -n $vmName --query "networkProfile.networkInterfaces[0].id" -o tsv
    $subnetId = az network nic show --ids $nicId --query "ipConfigurations[0].subnet.id" -o tsv
    $vnetId = $subnetId -replace "/subnets/.*", ""
    Write-Host "Assigning Reader role to VNET: $vnetId"
    az role assignment create --assignee $groupObjectId --role $role --scope $vnetId
}

# Assign Key Vault Secrets User role to all Key Vaults
$keyVaults = az keyvault list -g $resourceGroup --query "[].{id:id, name:name}" -o json | ConvertFrom-Json

foreach ($kv in $keyVaults) {
    $kvId = $kv.id
    $kvName = $kv.name

    Write-Host "Enabling RBAC on Key Vault: $kvName"
    az keyvault update --name $kvName --resource-group $resourceGroup --enable-rbac-authorization true

    Write-Host "Assigning Key Vault Secrets User role to Key Vault: $kvId"
    az role assignment create --assignee $groupObjectId --role "$keyVaultReaderRole" --scope $kvId
}

Write-Host "RBAC assignments completed."







