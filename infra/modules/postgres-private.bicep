@description('Azure location')
param location string
@description('Postgres server name')
param serverName string
@description('Database name')
param databaseName string = 'n8ndb'
@description('Admin login name')
param adminLogin string = 'n8nadmin'
@secure()
@description('Admin password (required)')
param adminPassword string
@description('Delegated subnet id for flexible server')
param delegatedSubnetId string
@description('Private DNS zone resource ID for postgres')
param privateDnsZoneId string

// Password provided by caller (generation cannot occur in variable using newGuid per Bicep rules)
var effectivePassword = adminPassword

resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2023-12-01-preview' = {
  name: serverName
  location: location
  sku: {
    name: 'Standard_B2s'
    tier: 'Burstable'
  }
  properties: {
    administratorLogin: adminLogin
    administratorLoginPassword: effectivePassword
    version: '15'
    network: {
      delegatedSubnetResourceId: delegatedSubnetId
      privateDnsZoneArmResourceId: privateDnsZoneId
      publicNetworkAccess: 'Disabled'
    }
    storage: {
      storageSizeGB: 64
      tier: 'P10'
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    authConfig: {
      activeDirectoryAuth: 'Disabled'
      passwordAuth: 'Enabled'
    }
  }
}

resource db 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-12-01-preview' = {
  name: databaseName
  parent: server
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// Private DNS zone for Postgres flexible server
resource pgPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.postgres.database.azure.com'
  location: 'global'
}

// The VNet link is created by caller module (network) so we just create record set here when server ready could be added later.
// For now rely on built-in flexible server private DNS integration (server sets A record in zone when linked). Caller must link zone.

var fqdn = '${server.name}.postgres.database.azure.com'

output serverName string = server.name
output fqdn string = fqdn
output databaseName string = databaseName
output adminLogin string = adminLogin
@secure()
output adminPassword string = effectivePassword
output connectionString string = 'postgresql://${adminLogin}:${effectivePassword}@${fqdn}:5432/${databaseName}'
