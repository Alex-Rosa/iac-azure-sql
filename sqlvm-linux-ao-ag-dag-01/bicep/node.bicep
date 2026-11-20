// One AG replica node and its own networking: VNet, NSG, static public IP, NIC, SQL data disk
// and the RHEL 9 VM. Deployed twice by resources.bicep (primary + secondary). Every resource
// name is '<namePrefix>-<nodeSuffix>-<type>', so the suffix alone identifies a node's objects.

param namePrefix string
param nodeSuffix string
param location string
@allowed(['primary', 'secondary'])
param agRole string
param addressSpace string
@description('Address space of the peer node\'s VNet - the only source allowed to reach the AG endpoint (5022)')
param peerAddressSpace string
param vmSize string
param adminUsername string
@secure()
param sshPublicKey string
param allowedSourceIps array
param sqlDataDiskSizeGB int
param sqlDataDiskSku string = 'Premium_LRS'
@description('Provisioned IOPS / MB/s - UltraSSD_LRS and PremiumV2_LRS only; 0 = platform default')
param sqlDataDiskIops int = 0
param sqlDataDiskMbps int = 0
@description('Availability zone for the VM, public IP and data disk. Empty = regional.')
param zone string = ''
param tags object

var nodeName = '${namePrefix}-${nodeSuffix}'
// First /24 after the network address, e.g. 10.10.0.0/16 -> 10.10.1.0/24
var subnetPrefix = cidrSubnet(addressSpace, 24, 1)
// null (not []) when regional, so a redeploy over an existing regional node changes nothing.
var zones = empty(zone) ? null : [zone]
// Ultra / Premium SSD v2: performance is provisioned separately from size, and host caching is not supported.
var provisionedPerfDisk = sqlDataDiskSku == 'UltraSSD_LRS' || sqlDataDiskSku == 'PremiumV2_LRS'
var sqlDiskPerf = union(
  provisionedPerfDisk && sqlDataDiskIops > 0 ? { diskIOPSReadWrite: sqlDataDiskIops } : {},
  provisionedPerfDisk && sqlDataDiskMbps > 0 ? { diskMBpsReadWrite: sqlDataDiskMbps } : {}
)

// Same first-boot orchestration on both nodes: format/mount the data disk (found by LUN) to /sqldata and
// open the ports SQL Server + the Always On mirroring endpoint need at the OS firewall level
// (the NSG below controls it at the network level; both must agree).
var cloudInit = '''
#cloud-config
package_update: true
packages:
  - wget
  - curl
  - openssl
  - python3
  - glibc
  - unixODBC
runcmd:
  - |
    # The data disk is LUN 10 (dataDisks below). Its device name depends on the VM generation (/dev/sdc on SCSI sizes,
    # /dev/nvme0n2 on NVMe sizes such as v6/v7), so look it up by LUN - never assume /dev/sdb.
    DEV=""
    for p in /dev/disk/azure/data/by-lun/10 /dev/disk/azure/scsi1/lun10; do
      if [ -e "$p" ]; then DEV=$(readlink -f "$p"); break; fi
    done
    if [ -n "$DEV" ] && ! mountpoint -q /sqldata 2>/dev/null; then
      if ! blkid "$DEV" &>/dev/null; then
        mkfs.xfs "$DEV"
      fi
      mkdir -p /sqldata
      UUID=$(blkid -s UUID -o value "$DEV")
      echo "UUID=$UUID /sqldata xfs defaults,nofail 0 2" >> /etc/fstab
      mount /sqldata
    fi
  - firewall-cmd --permanent --add-port=1433/tcp || true
  - firewall-cmd --permanent --add-port=5022/tcp || true
  - firewall-cmd --reload || true
'''

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: '${nodeName}-vnet'
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
        }
      }
    ]
  }
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${nodeName}-nsg'
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
      {
        name: 'allow-ag-endpoint-from-peer'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '5022'
          sourceAddressPrefix: peerAddressSpace
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${nodeName}-pip'
  location: location
  tags: tags
  zones: zones
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${nodeName}-nic'
  location: location
  tags: tags
  properties: {
    networkSecurityGroup: {
      id: nsg.id
    }
    ipConfigurations: [
      {
        name: 'internal'
        properties: {
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: pip.id
          }
        }
      }
    ]
  }
}

resource sqlDisk 'Microsoft.Compute/disks@2023-10-02' = {
  name: '${nodeName}-sqldata'
  location: location
  tags: tags
  zones: zones
  sku: {
    name: sqlDataDiskSku
  }
  properties: union({
    creationData: {
      createOption: 'Empty'
    }
    diskSizeGB: sqlDataDiskSizeGB
  }, sqlDiskPerf)
}

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: '${nodeName}-vm'
  location: location
  tags: union(tags, { agRole: agRole })
  zones: zones
  properties: {
    additionalCapabilities: sqlDataDiskSku == 'UltraSSD_LRS' ? { ultraSSDEnabled: true } : null
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      // The Linux hostname becomes @@SERVERNAME, which is also the AG replica name.
      computerName: nodeName
      adminUsername: adminUsername
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'RedHat'
        offer: 'RHEL'
        sku: '9-lvm-gen2'
        version: 'latest'
      }
      osDisk: {
        name: '${nodeName}-osdisk'
        createOption: 'FromImage'
        caching: 'ReadWrite'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        diskSizeGB: 128
      }
      dataDisks: [
        {
          lun: 10
          name: sqlDisk.name
          createOption: 'Attach'
          managedDisk: {
            id: sqlDisk.id
          }
          caching: provisionedPerfDisk ? 'None' : 'ReadWrite'
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

output nodeName string = nodeName
output vnetName string = vnet.name
output publicIP string = pip.properties.ipAddress
output privateIP string = nic.properties.ipConfigurations[0].properties.privateIPAddress
