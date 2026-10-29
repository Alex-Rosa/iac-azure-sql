targetScope = 'subscription'

@description('Short name prefix for all resources')
param prefix string = 'sqlvm'

@description('Unique identifier that is part of every resource name (sqlvm-linux-ag.ps1 -Identifier, e.g. 257672)')
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

@description('Resource group that holds both nodes (sqlvm-linux-ag.ps1 derives it from prefix/environment/suffixes)')
param resourceGroupName string = '${prefix}-${environment}-${primaryNodeSuffix}-${secondaryNodeSuffix}-rg'

@description('Azure region for BOTH replicas')
param location string

@description('Address space of the stack VNet (shared by both nodes). Must not overlap any other VNet you plan to peer with.')
param addressSpace string = '10.10.0.0/16'

@description('Availability zone of the primary VM (e.g. "1"). Empty = no zone (availability set or regional placement).')
param primaryZone string = ''

@description('Availability zone of the secondary VM (e.g. "2"). Must differ from primaryZone to survive a zone failure.')
param secondaryZone string = ''

@description('Put both VMs in one availability set (separate fault/update domains). Used when the region or size has no zones.')
param useAvailabilitySet bool = false

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
  project: 'sqlvm-ag-single-region'
  purpose: 'always-on-availability-group-single-region'
  managedBy: 'bicep'
}

var namePrefix = '${prefix}-${environment}'
var stackTags = union(tags, {
  primaryNode: primaryNodeSuffix
  secondaryNode: secondaryNodeSuffix
})

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
  tags: stackTags
}

module resources 'resources.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    namePrefix: namePrefix
    primaryNodeSuffix: primaryNodeSuffix
    secondaryNodeSuffix: secondaryNodeSuffix
    location: location
    addressSpace: addressSpace
    primaryZone: primaryZone
    secondaryZone: secondaryZone
    useAvailabilitySet: useAvailabilitySet
    vmSize: vmSize
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    allowedSourceIps: allowedSourceIps
    sqlDataDiskSizeGB: sqlDataDiskSizeGB
    tags: stackTags
  }
}

output resourceGroup string = rg.name
output vnetName string = resources.outputs.vnetName
output primaryNodeName string = resources.outputs.primaryNodeName
output primaryPublicIP string = resources.outputs.primaryPublicIP
output primaryPrivateIP string = resources.outputs.primaryPrivateIP
output secondaryNodeName string = resources.outputs.secondaryNodeName
output secondaryPublicIP string = resources.outputs.secondaryPublicIP
output secondaryPrivateIP string = resources.outputs.secondaryPrivateIP
