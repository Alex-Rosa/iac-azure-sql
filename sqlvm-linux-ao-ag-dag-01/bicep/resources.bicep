param namePrefix string
param primaryNodeSuffix string
param secondaryNodeSuffix string
param primaryLocation string
param secondaryLocation string
param primaryAddressSpace string
param secondaryAddressSpace string
param vmSize string
param adminUsername string
@secure()
param sshPublicKey string
param allowedSourceIps array
param sqlDataDiskSizeGB int
param tags object

// ── Primary replica (its own VNet/NSG/PIP/NIC/disk/VM) ─────────────────────────
module primary 'node.bicep' = {
  name: 'node-${primaryNodeSuffix}'
  params: {
    namePrefix: namePrefix
    nodeSuffix: primaryNodeSuffix
    location: primaryLocation
    agRole: 'primary'
    addressSpace: primaryAddressSpace
    peerAddressSpace: secondaryAddressSpace
    vmSize: vmSize
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    allowedSourceIps: allowedSourceIps
    sqlDataDiskSizeGB: sqlDataDiskSizeGB
    tags: tags
  }
}

// ── Secondary replica ────────────────────────────────────────────────────────
module secondary 'node.bicep' = {
  name: 'node-${secondaryNodeSuffix}'
  params: {
    namePrefix: namePrefix
    nodeSuffix: secondaryNodeSuffix
    location: secondaryLocation
    agRole: 'secondary'
    addressSpace: secondaryAddressSpace
    peerAddressSpace: primaryAddressSpace
    vmSize: vmSize
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    allowedSourceIps: allowedSourceIps
    sqlDataDiskSizeGB: sqlDataDiskSizeGB
    tags: tags
  }
}

// ── VNet peering (global when the regions differ; no gateway needed) ────────────
resource vnetPrimary 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: '${namePrefix}-${primaryNodeSuffix}-vnet'
}

resource vnetSecondary 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: '${namePrefix}-${secondaryNodeSuffix}-vnet'
}

resource peerPrimaryToSecondary 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: vnetPrimary
  name: 'to-${secondaryNodeSuffix}'
  properties: {
    remoteVirtualNetwork: {
      id: vnetSecondary.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
  }
  dependsOn: [
    primary
    secondary
  ]
}

resource peerSecondaryToPrimary 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: vnetSecondary
  name: 'to-${primaryNodeSuffix}'
  properties: {
    remoteVirtualNetwork: {
      id: vnetPrimary.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: false
    allowGatewayTransit: false
    useRemoteGateways: false
  }
  dependsOn: [
    primary
    secondary
  ]
}

output primaryNodeName string = primary.outputs.nodeName
output primaryPublicIP string = primary.outputs.publicIP
output primaryPrivateIP string = primary.outputs.privateIP
output secondaryNodeName string = secondary.outputs.nodeName
output secondaryPublicIP string = secondary.outputs.publicIP
output secondaryPrivateIP string = secondary.outputs.privateIP
