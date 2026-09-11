// Deploys a standalone Azure SQL VM (SQL Server IaaS on a Windows VM)
// including a new VNet/subnet, NSG, optional public IP, and registration
// with the SQL VM resource provider (Microsoft.SqlVirtualMachine).

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Name of the SQL virtual machine (also used as the computer name, max 15 chars).')
@maxLength(15)
param vmName string

@description('Size of the virtual machine.')
param vmSize string = 'Standard_D4s_v5'

@description('Admin username for the Windows VM.')
param adminUsername string

@description('Admin password for the Windows VM.')
@secure()
param adminPassword string

@description('SQL Server edition/image SKU to deploy.')
@allowed([
  'standard'
  'enterprise'
  'developer'
  'express'
])
param sqlSku string = 'standard'

@description('SQL Server licensing model. Use AHUB if you have existing SQL Server licenses with Software Assurance.')
@allowed([
  'PAYG'
  'AHUB'
])
param sqlServerLicenseType string = 'PAYG'

@description('Deploy a public IP address for the VM.')
param deployPublicIp bool = true

@description('Allow inbound SQL Server (TCP 1433) traffic from the allowedSourceIpAddress.')
param enableSqlPublicAccess bool = false

@description('Source IP address (or CIDR) allowed to reach RDP (3389) and, if enabled, SQL (1433). Use your own public IP for security; avoid "*" in production.')
param allowedSourceIpAddress string = '*'

@description('Address prefix for the new virtual network.')
param vnetAddressPrefix string = '10.20.0.0/24'

@description('Address prefix for the VM subnet.')
param subnetAddressPrefix string = '10.20.0.0/26'

var vnetName = '${vmName}-vnet'
var subnetName = 'sql-subnet'
var nsgName = '${vmName}-nsg'
var publicIpName = '${vmName}-pip'
var nicName = '${vmName}-nic'
var sqlImageOffer = 'sql2022-ws2022'

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: concat([
      {
        name: 'Allow-RDP'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: allowedSourceIpAddress
          destinationAddressPrefix: '*'
        }
      }
    ], enableSqlPublicAccess ? [
      {
        name: 'Allow-SQL'
        properties: {
          priority: 1010
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '1433'
          sourceAddressPrefix: allowedSourceIpAddress
          destinationAddressPrefix: '*'
        }
      }
    ] : [])
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetAddressPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = if (deployPublicIp) {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: '${vnet.id}/subnets/${subnetName}'
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: deployPublicIp ? {
            id: publicIp.id
          } : null
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  plan: {
    name: sqlSku
    publisher: 'MicrosoftSQLServer'
    product: sqlImageOffer
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftSQLServer'
        offer: sqlImageOffer
        sku: sqlSku
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
      dataDisks: [
        {
          lun: 0
          createOption: 'Empty'
          diskSizeGB: 256
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
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
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource sqlVirtualMachine 'Microsoft.SqlVirtualMachine/sqlVirtualMachines@2023-10-01' = {
  name: vmName
  location: location
  properties: {
    virtualMachineResourceId: vm.id
    sqlServerLicenseType: sqlServerLicenseType
    sqlManagement: 'Full'
    sqlImageOffer: sqlImageOffer
    sqlImageSku: sqlSku
    storageConfigurationSettings: {
      diskConfigurationType: 'NEW'
      storageWorkloadType: 'OLTP'
      sqlDataSettings: {
        luns: [
          0
        ]
      }
    }
    autoPatchingSettings: {
      enable: true
      dayOfWeek: 'Sunday'
      maintenanceWindowStartingHour: 2
      maintenanceWindowDuration: 60
    }
  }
}

output vmName string = vm.name
output publicIpAddress string = publicIp.?properties.?ipAddress ?? ''
output resourceId string = vm.id
