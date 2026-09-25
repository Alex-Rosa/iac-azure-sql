targetScope = 'resourceGroup'

@description('Must match the -Prefix used for the main deployment')
param prefix string = 'sqlvm'

@description('Unique identifier that is part of every resource name (deploy.ps1 -Identifier, e.g. 257672)')
@minLength(1)
@maxLength(15)
param environment string

@description('Object-name suffix of the primary node (e.g. node-1) - must match the main deployment')
param primaryNodeSuffix string

@description('Object-name suffix of the secondary node (e.g. node-2) - must match the main deployment')
param secondaryNodeSuffix string

@description('Region of the primary node\'s VNet (deploy-bastion.ps1 reads it from the live VNet)')
param primaryLocation string

@description('Region of the secondary node\'s VNet (deploy-bastion.ps1 reads it from the live VNet)')
param secondaryLocation string

@description('Address space of the primary VNet (read from the live VNet); AzureBastionSubnet is carved out of it')
param primaryAddressSpace string

@description('Address space of the secondary VNet (read from the live VNet)')
param secondaryAddressSpace string

param tags object = {
  project: 'sqlvm-ag'
  purpose: 'bastion-access'
  managedBy: 'bicep'
}

var namePrefix = '${prefix}-${environment}'
var nodes = [
  {
    suffix: primaryNodeSuffix
    location: primaryLocation
    // 10.10.0.0/16 -> 10.10.2.0/26 (the VM subnet is 10.10.1.0/24)
    bastionSubnet: cidrSubnet(primaryAddressSpace, 26, 8)
  }
  {
    suffix: secondaryNodeSuffix
    location: secondaryLocation
    bastionSubnet: cidrSubnet(secondaryAddressSpace, 26, 8)
  }
]

// Attaches to the VNets the main deployment already created - not redeclared, just referenced.
// Deliberately does NOT touch their existing 'default' subnet (which has VM NICs attached):
// redeclaring a VNet's full subnets array on redeploy can make Azure try to delete any subnet
// missing from that array, which fails once something is attached to it. Adding
// AzureBastionSubnet as its own child resource below is a purely additive operation instead.
resource vnets 'Microsoft.Network/virtualNetworks@2023-09-01' existing = [for n in nodes: {
  name: '${namePrefix}-${n.suffix}-vnet'
}]

resource bastionSubnets 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' = [for (n, i) in nodes: {
  parent: vnets[i]
  name: 'AzureBastionSubnet'
  properties: {
    addressPrefix: n.bastionSubnet
  }
}]

resource bastionPips 'Microsoft.Network/publicIPAddresses@2023-09-01' = [for n in nodes: {
  name: '${namePrefix}-${n.suffix}-bastion-pip'
  location: n.location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}]

// Standard SKU (not Basic) is required for native-client tunneling (az network bastion tunnel /
// ssh) - Basic SKU only supports browser-based RDP/SSH sessions via the Azure portal.
resource bastions 'Microsoft.Network/bastionHosts@2023-09-01' = [for (n, i) in nodes: {
  name: '${namePrefix}-${n.suffix}-bastion'
  location: n.location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    enableTunneling: true
    ipConfigurations: [
      {
        name: 'bastionIpConfig'
        properties: {
          subnet: {
            id: bastionSubnets[i].id
          }
          publicIPAddress: {
            id: bastionPips[i].id
          }
        }
      }
    ]
  }
}]

output bastionPrimaryName string = bastions[0].name
output bastionSecondaryName string = bastions[1].name
