@description('Azure location')
param location string
@description('VNet name')
param vnetName string
@description('Storage account name (must be globally unique, <=24 chars)')
param storageAccountName string
@description('File share name for n8n persistent data')
param fileShareName string = 'n8ndata'
@description('Enable private endpoints (always true for Small/Prod initial version)')
param enablePrivateEndpoints bool = true

// Basic VNet with two subnets: one for private endpoints, one delegated for Postgres (optional usage by caller)
var peSubnetName = 'pe-subnet'
var dbSubnetName = 'db-subnet'

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
    ]
  }
}

// Storage Account for Azure Files
resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    allowSharedKeyAccess: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: enablePrivateEndpoints ? 'Deny' : 'Allow'
    }
    isHnsEnabled: false
    largeFileSharesState: 'Enabled'
  }
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  name: '${storage.name}/default/${fileShareName}'
  properties: {
    accessTier: 'TransactionOptimized'
    enabledProtocols: 'SMB'
  }
}

// Private DNS zone for file shares (optional future use). Creating anyway to simplify later enhancements.
resource privateDnsZoneStorage 'Microsoft.Network/privateDnsZones@2024-06-01' = if (enablePrivateEndpoints) {
  name: 'privatelink.file.core.windows.net'
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

// Private Endpoint for storage file service
resource storagePe 'Microsoft.Network/privateEndpoints@2021-08-01' = if (enablePrivateEndpoints) {
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
          privateLinkServiceId: storage.id
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

resource peZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2021-08-01' = if (enablePrivateEndpoints) {
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
output storageAccountName string = storage.name
@secure()
output storageAccountKey string = listKeys(storage.id, '2023-01-01').keys[0].value
output fileShareName string = fileShareName
output postgresPrivateDnsZoneId string = enablePrivateEndpoints ? privateDnsZonePostgres.id : ''
