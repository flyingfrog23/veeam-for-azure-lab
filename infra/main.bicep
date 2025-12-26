// infra/main.bicep
// Lab baseline for Veeam in Azure:
// - Networking (VNet/Subnet/NSG)
// - Windows VM you can use for Veeam Backup & Replication (VBR) console/server
// - Storage account for backup repositories / staging (lab purposes)
// - (Optional) Recovery Services Vault (handy for testing Azure VM backup too)

targetScope = 'resourceGroup'

@description('Resource name prefix, e.g. veeam-lab')
param prefix string = 'veeam-lab'

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Admin username for the Windows VM (VBR server)')
param adminUsername string

@secure()
@description('Admin password for the Windows VM (VBR server). Use a strong password.')
param adminPassword string

@description('Allowed source IP/CIDR for RDP access to the VM (lock this down!). Example: 203.0.113.4/32')
param allowedRdpSource string = '0.0.0.0/0'

@description('VNet address space')
param vnetAddressPrefix string = '10.50.0.0/16'

@description('Subnet address prefix')
param subnetAddressPrefix string = '10.50.1.0/24'

@description('Windows VM size for VBR')
param vmSize string = 'Standard_D4s_v5'

@description('Windows OS image SKU')
@allowed([
  '2019-Datacenter'
  '2022-Datacenter'
])
param windowsSku string = '2022-Datacenter'

@description('Storage account SKU for lab repository')
@allowed([
  'Standard_LRS'
  'Standard_GRS'
  'Standard_ZRS'
])
param storageSku string = 'Standard_LRS'

@description('Create a Recovery Services Vault (true/false)')
param createRecoveryVault bool = true

var vnetName = '${prefix}-vnet'
var subnetName = '${prefix}-subnet'
var nsgName = '${prefix}-nsg'
var pipName = '${prefix}-pip'
var nicName = '${prefix}-nic'
var vmName = '${prefix}-vbr'
var saName = toLower(replace('${uniqueString(resourceGroup().id, prefix)}${prefix}', '-', ''))
var vaultName = '${prefix}-rsv'

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-RDP'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: allowedRdpSource
          destinationAddressPrefix: '*'
        }
      }
      // Add more rules as needed (e.g., HTTPS 443 for installers, etc.)
    ]
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

resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: pipName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
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
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: pip.id
          }
          subnet: {
            id: vnet.properties.subnets[0].id
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: windowsSku
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
      // Optional: add a data disk to use as a local repository for lab testing
      dataDisks: [
        {
          lun: 0
          name: '${vmName}-data1'
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
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: saName
  location: location
  sku: {
    name: storageSku
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    accessTier: 'Hot'
  }
}

resource vault 'Microsoft.RecoveryServices/vaults@2024-04-01' = if (createRecoveryVault) {
  name: vaultName
  location: location
  properties: {}
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
}

output vbrVmName string = vm.name
output vbrPublicIp string = pip.properties.ipAddress
output vnetId string = vnet.id
output subnetId string = vnet.properties.subnets[0].id
output storageAccountName string = storage.name
output recoveryVaultName string = createRecoveryVault ? vault.name : ''
