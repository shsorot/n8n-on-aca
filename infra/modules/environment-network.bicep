@description('Azure location')
param location string
@description('VNet name')
param vnetName string
@description('Storage account name (must be globally unique, <=24 chars)')
param storageAccountName string
@description('File share name for n8n persistent data')
param fileShareName string = 'n8ndata'
@description('Use Azure Managed File Share (Microsoft.FileShares) instead of traditional Storage Account')
param useManagedFileShare bool = true
@description('Enable private endpoints (always true for Small/Prod initial version)')
param enablePrivateEndpoints bool = true

// Basic VNet with two subnets: one for private endpoints, one delegated for Postgres (optional usage by caller)
var peSubnetName = 'pe-subnet'
var dbSubnetName = 'db-subnet'
var acaSubnetName = 'aca-subnet'

resource vnet 'Microsoft.Network/virtualNetworks@2024-03-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.50.0.0/16' ]
    }
    subnets: [
      {
        name: peSubnetName
        properties: {
          addressPrefixes: [ '10.50.1.0/24' ]
        }
      }
      {
        name: dbSubnetName
        properties: {
          addressPrefixes: [ '10.50.2.0/24' ]
          delegations: [
            {
              name: 'flexibleServers'
              properties: {
                serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
              }
            }
          ]
        }
      }
      {
        name: acaSubnetName
        properties: {
          addressPrefixes: [ '10.50.3.0/24' ]
          delegations: [
            {
              name: 'acaDelegation'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
    ]
  }
}

// Option 1: Azure Managed File Share (Microsoft.FileShares)
resource managedFileShare 'Microsoft.FileShares/fileShares@2025-06-01-preview' = if (useManagedFileShare) {
  name: fileShareName
  location: location
  properties: {
    protocol: 'NFS'
    provisionedStorageGiB: 100
    mediaTier: 'SSD'
    redundancy: 'Zone'
    publicNetworkAccess: 'Disabled'
  }
}

// Option 2: Traditional Storage Account for Azure Files
resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = if (!useManagedFileShare) {
  name: storageAccountName
  location: location
  sku: {
    name: 'Premium_LRS'
  }
  kind: 'FileStorage'
  properties: {
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: false
    allowSharedKeyAccess: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: enablePrivateEndpoints ? 'Deny' : 'Allow'
    }
  }
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = if (!useManagedFileShare) {
  name: '${storage.name}/default/${fileShareName}'
  properties: {
    enabledProtocols: 'NFS'
    shareQuota: 100
  }
}

// Private DNS zone for file shares
resource privateDnsZoneStorage 'Microsoft.Network/privateDnsZones@2024-06-01' = if (enablePrivateEndpoints) {
  name: 'privatelink.file.${environment().suffixes.storage}'
  location: 'global'
}

resource dnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (enablePrivateEndpoints) {
  name: 'stg-link'
  parent: privateDnsZoneStorage
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

// Private DNS zone for Postgres flexible servers
resource privateDnsZonePostgres 'Microsoft.Network/privateDnsZones@2024-06-01' = if (enablePrivateEndpoints) {
  name: 'privatelink.postgres.database.azure.com'
  location: 'global'
}

resource dnsVnetLinkPostgres 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (enablePrivateEndpoints) {
  name: 'pg-link'
  parent: privateDnsZonePostgres
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

// Private Endpoint for Managed File Share
resource managedFileSharePe 'Microsoft.Network/privateEndpoints@2024-03-01' = if (useManagedFileShare && enablePrivateEndpoints) {
  name: '${fileShareName}-pe'
  location: location
  properties: {
    subnet: {
      id: vnet.properties.subnets[0].id
    }
    privateLinkServiceConnections: [
      {
        name: 'fileshare'
        properties: {
          privateLinkServiceId: managedFileShare!.id
          groupIds: [ 'FileShare' ]
          privateLinkServiceConnectionState: {
            status: 'Approved'
            actionsRequired: 'None'
          }
        }
      }
    ]
  }
}

resource managedFileSharePeZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-03-01' = if (useManagedFileShare && enablePrivateEndpoints) {
  name: 'fileShareZoneGroup'
  parent: managedFileSharePe
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'managedFileShare'
        properties: {
          privateDnsZoneId: privateDnsZoneStorage.id
        }
      }
    ]
  }
}

// Private Endpoint for Storage Account file service
resource storagePe 'Microsoft.Network/privateEndpoints@2024-03-01' = if (!useManagedFileShare && enablePrivateEndpoints) {
  name: '${storageAccountName}-pe'
  location: location
  properties: {
    subnet: {
      id: vnet.properties.subnets[0].id
    }
    privateLinkServiceConnections: [
      {
        name: 'file'
        properties: {
          privateLinkServiceId: storage!.id
          groupIds: [ 'file' ]
          privateLinkServiceConnectionState: {
            status: 'Approved'
            actionsRequired: 'None'
          }
        }
      }
    ]
  }
}

resource storagePeZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-03-01' = if (!useManagedFileShare && enablePrivateEndpoints) {
  name: 'fileZoneGroup'
  parent: storagePe
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'storageFile'
        properties: {
          privateDnsZoneId: privateDnsZoneStorage.id
        }
      }
    ]
  }
}

// Outputs
output vnetId string = vnet.id
output peSubnetId string = vnet.properties.subnets[0].id
output dbSubnetId string = vnet.properties.subnets[1].id
output storageAccountName string = useManagedFileShare ? '' : storage!.name
@secure()
output storageAccountKey string = useManagedFileShare ? '' : storage!.listKeys().keys[0].value
output fileShareName string = fileShareName
output fileShareMountPath string = useManagedFileShare ? managedFileShare!.properties.hostName : '${storage!.name}.file.${environment().suffixes.storage}'
output postgresPrivateDnsZoneId string = enablePrivateEndpoints ? privateDnsZonePostgres.id : ''
output acaSubnetId string = vnet.properties.subnets[2].id
