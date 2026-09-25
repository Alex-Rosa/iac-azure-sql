targetScope = 'subscription'

@description('Short name prefix for all resources')
param prefix string = 'sqlvm'

@description('Unique identifier that is part of every resource name (deploy.ps1 -Identifier, e.g. 257672)')
@minLength(1)
@maxLength(15)
param environment string

@description('Object-name suffix for the PRIMARY replica node, e.g. node-1. Every primary-side resource name ends with it.')
@minLength(1)
@maxLength(20)
param primaryNodeSuffix string

@description('Object-name suffix for the SECONDARY replica node, e.g. node-2. Every secondary-side resource name ends with it.')
@minLength(1)
@maxLength(20)
param secondaryNodeSuffix string

@description('Resource group that holds both nodes (deploy.ps1 derives it from prefix/environment/suffixes)')
param resourceGroupName string = '${prefix}-${environment}-${primaryNodeSuffix}-${secondaryNodeSuffix}-rg'

@description('Azure region for the PRIMARY replica')
param primaryLocation string

@description('Azure region for the SECONDARY replica (may equal primaryLocation for a single-region pair)')
param secondaryLocation string

@description('Address space of the primary VNet (/16). Must not overlap the secondary VNet, or any other stack you plan to peer with (e.g. for a Distributed AG).')
param primaryAddressSpace string = '10.10.0.0/16'

@description('Address space of the secondary VNet (/16)')
param secondaryAddressSpace string = '10.20.0.0/16'

@description('VM size for both nodes')
param vmSize string = 'Standard_D4as_v7'

@description('Admin username for both VMs')
param adminUsername string = 'azureuser'

@description('SSH public key content, injected on both VMs')
@secure()
param sshPublicKey string

@description('Allowed source IP ranges for SSH (22) and SQL Server (1433) from outside Azure')
param allowedSourceIps array = ['0.0.0.0/0']

@description('SQL data disk size in GB, on both nodes')
param sqlDataDiskSizeGB int = 256

@description('Tags applied to every resource')
param tags object = {
  project: 'sqlvm-ag'
  purpose: 'always-on-availability-group-cross-region'
  managedBy: 'bicep'
}

var namePrefix = '${prefix}-${environment}'
var stackTags = union(tags, {
  primaryNode: primaryNodeSuffix
  secondaryNode: secondaryNodeSuffix
})

// Single resource group holds both regions' resources - a resource group's `location` is
// only metadata for where its own deployment history is stored; the VMs/VNets inside it
// are independently placed in primaryLocation / secondaryLocation.
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: primaryLocation
  tags: stackTags
}

module resources 'resources.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    namePrefix: namePrefix
    primaryNodeSuffix: primaryNodeSuffix
    secondaryNodeSuffix: secondaryNodeSuffix
    primaryLocation: primaryLocation
    secondaryLocation: secondaryLocation
    primaryAddressSpace: primaryAddressSpace
    secondaryAddressSpace: secondaryAddressSpace
    vmSize: vmSize
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    allowedSourceIps: allowedSourceIps
    sqlDataDiskSizeGB: sqlDataDiskSizeGB
    tags: stackTags
  }
}

output resourceGroup string = rg.name
output primaryNodeName string = resources.outputs.primaryNodeName
output primaryPublicIP string = resources.outputs.primaryPublicIP
output primaryPrivateIP string = resources.outputs.primaryPrivateIP
output secondaryNodeName string = resources.outputs.secondaryNodeName
output secondaryPublicIP string = resources.outputs.secondaryPublicIP
output secondaryPrivateIP string = resources.outputs.secondaryPrivateIP
