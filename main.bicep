param location string = resourceGroup().location
param adminUsername string
@secure()
param adminPassword string

param vnetCidr string = '10.50.0.0/16'
param subnetCidr string = '10.50.1.0/24'

// Restrict RDP to your public IP in CIDR form, e.g. "203.0.113.10/32"
param rdpSourceCidr string

param vmName string = 'vbr-lab-01'
param vmSize string = 'Standard_D4s_v5'

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-vbr'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-RDP-From-MyIP'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: rdpSourceCidr
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'vnet-veeam-lab'
  location: location
  properties: {
    addressSpace: { addressPrefixes: [vnetCidr] }
    subnets: [
      {
        name: 'snet-vbr'
        properties: {
          addressPrefix: subnetCidr
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'pip-vbr'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'nic-${vmName}'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: vnet.properties.subnets[0].id }
          publicIPAddress: { id: pip.id }
        }
      }
    ]
  }
}

resource vbrVm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nic.id }]
    }
  }
}

output vbrPublicIp string = pip.properties.ipAddress
