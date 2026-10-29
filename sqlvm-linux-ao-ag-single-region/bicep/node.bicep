// One AG replica node: NSG, static public IP, NIC, SQL data disk and the RHEL 9 VM, in the
// stack's shared subnet. Deployed twice by resources.bicep (primary + secondary). Every resource
// name is '<namePrefix>-<nodeSuffix>-<type>', so the suffix alone identifies a node's objects.

param namePrefix string
param nodeSuffix string
param location string
@description('Availability zone ("1", "2", "3"), or empty for no zone')
param zone string
@description('Resource ID of the stack availability set, or empty for none')
param availabilitySetId string
@allowed(['primary', 'secondary'])
param agRole string
param subnetId string
@description('Address space of the stack VNet - the only source allowed to reach the AG endpoint (5022)')
param vnetAddressSpace string
param vmSize string
param adminUsername string
@secure()
param sshPublicKey string
param allowedSourceIps array
param sqlDataDiskSizeGB int
param tags object

var nodeName = '${namePrefix}-${nodeSuffix}'
var zones = empty(zone) ? [] : [zone]

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
        name: 'allow-ag-endpoint-from-vnet'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '5022'
          sourceAddressPrefix: vnetAddressSpace
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
  sku: {
    name: 'Standard'
  }
  // Same zone as the VM: the IP goes down with its zone only, like the VM itself.
  zones: zones
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
            id: subnetId
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
  sku: {
    name: 'Premium_LRS'
  }
  // A zonal VM can only attach disks from its own zone.
  zones: zones
  properties: {
    creationData: {
      createOption: 'Empty'
    }
    diskSizeGB: sqlDataDiskSizeGB
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: '${nodeName}-vm'
  location: location
  tags: union(tags, { agRole: agRole })
  zones: zones
  properties: {
    availabilitySet: empty(availabilitySetId) ? null : {
      id: availabilitySetId
    }
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
          caching: 'ReadWrite'
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
output publicIP string = pip.properties.ipAddress
output privateIP string = nic.properties.ipConfigurations[0].properties.privateIPAddress
