param namePrefix string
param primaryNodeSuffix string
param secondaryNodeSuffix string
param location string
param addressSpace string
param primaryZone string
param secondaryZone string
param useAvailabilitySet bool
param vmSize string
param adminUsername string
@secure()
param sshPublicKey string
param allowedSourceIps array
param sqlDataDiskSizeGB int
param tags object

// Stack-level objects are named after both suffixes, like the resource group:
// '<namePrefix>-<primary>-<secondary>-<type>'. Removing one node never touches them.
var stackName = '${namePrefix}-${primaryNodeSuffix}-${secondaryNodeSuffix}'
// First /24 after the network address, e.g. 10.10.0.0/16 -> 10.10.1.0/24
var subnetPrefix = cidrSubnet(addressSpace, 24, 1)

// ── Subnet NSG ─────────────────────────────────────────────────────────────────
// Some subscriptions run a policy that attaches its own deny-all NSG to any subnet without one,
// which silently blocks SSH/SQL even when the NIC NSGs allow them. Owning the subnet NSG avoids
// that; its SSH/SQL rules carry the same names as the NIC rules, so refresh-access updates both.
// Traffic inside the VNet (AG endpoint 5022 between the nodes) is allowed by the default
// AllowVnetInBound rule.
resource subnetNsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${stackName}-subnet-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-ssh'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefixes: allowedSourceIps
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'allow-sqlserver'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '1433'
          sourceAddressPrefixes: allowedSourceIps
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// ── One VNet / subnet shared by both nodes (same region: no peering needed) ─────
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: '${stackName}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [addressSpace]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: subnetPrefix
          networkSecurityGroup: {
            id: subnetNsg.id
          }
        }
      }
    ]
  }
}

// ── Availability set (only when the VMs are not spread across zones) ───────────
resource avset 'Microsoft.Compute/availabilitySets@2023-09-01' = if (useAvailabilitySet) {
  name: '${stackName}-avset'
  location: location
  tags: tags
  sku: {
    name: 'Aligned' // required for managed disks
  }
  properties: {
    platformFaultDomainCount: 2
    platformUpdateDomainCount: 5
  }
}

// ── Primary replica ────────────────────────────────────────────────────────────
module primary 'node.bicep' = {
  name: 'node-${primaryNodeSuffix}'
  params: {
    namePrefix: namePrefix
    nodeSuffix: primaryNodeSuffix
    location: location
    zone: primaryZone
    availabilitySetId: useAvailabilitySet ? avset.id : ''
    agRole: 'primary'
    subnetId: vnet.properties.subnets[0].id
    vnetAddressSpace: addressSpace
    vmSize: vmSize
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    allowedSourceIps: allowedSourceIps
    sqlDataDiskSizeGB: sqlDataDiskSizeGB
    tags: tags
  }
}

// ── Secondary replica ──────────────────────────────────────────────────────────
module secondary 'node.bicep' = {
  name: 'node-${secondaryNodeSuffix}'
  params: {
    namePrefix: namePrefix
    nodeSuffix: secondaryNodeSuffix
    location: location
    zone: secondaryZone
    availabilitySetId: useAvailabilitySet ? avset.id : ''
    agRole: 'secondary'
    subnetId: vnet.properties.subnets[0].id
    vnetAddressSpace: addressSpace
    vmSize: vmSize
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    allowedSourceIps: allowedSourceIps
    sqlDataDiskSizeGB: sqlDataDiskSizeGB
    tags: tags
  }
}

output vnetName string = vnet.name
output primaryNodeName string = primary.outputs.nodeName
output primaryPublicIP string = primary.outputs.publicIP
output primaryPrivateIP string = primary.outputs.privateIP
output secondaryNodeName string = secondary.outputs.nodeName
output secondaryPublicIP string = secondary.outputs.publicIP
output secondaryPrivateIP string = secondary.outputs.privateIP
