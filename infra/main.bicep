targetScope = 'resourceGroup'

@minLength(1)
@maxLength(64)
@description('Name used as prefix for all resources')
param environmentName string

@description('Primary location for all resources')
param location string = 'centralus'

@description('Deployment tier: Try | Small | Production')
@allowed([
  'Try'
  'Small'
  'Production'
])
param deploymentTier string = 'Try'

@description('(Try tier only) existing ACA environment name; blank = create new one')
param acaEnvironmentName string = ''

@description('n8n Docker image')
param image string = 'docker.n8n.io/n8nio/n8n'

// Tier flags
var isTry = deploymentTier == 'Try'
var isProd = deploymentTier == 'Production'

// Try tier uses app-base directly with no persistence or database
var createNewEnvironment = isTry && empty(acaEnvironmentName)

// Common naming for Small/Prod
var baseName = toLower(replace(environmentName, '_', '-'))
var envNameSp = 'env-${baseName}'
var vnetName = 'vnet-${baseName}'
// storage account name: 3-24 lowercase alphanumeric only. Compose from cleaned base + hash, then trim.
var storageHash = toLower(uniqueString(resourceGroup().id, baseName))
var cleanedBase = replace(baseName, '-', '')
var storageAccountRaw = '${cleanedBase}${storageHash}'
var storageAccountName = length(storageAccountRaw) > 24 ? substring(storageAccountRaw, 0, 24) : storageAccountRaw
var fileShareName = 'n8ndata'
var pgServerName = 'pg-${baseName}'
@secure()
param postgresAdminPassword string = replace(newGuid(), '-', '')

// Network + storage for Small/Prod
module persistence 'modules/environment-network.bicep' = if (!isTry) {
  name: 'persistence'
  params: {
    location: location
    vnetName: vnetName
    storageAccountName: storageAccountName
    fileShareName: fileShareName
  }
}

// Postgres for Production only
module postgres 'modules/postgres-private.bicep' = if (isProd) {
  name: 'postgres'
  params: {
    location: location
    serverName: pgServerName
    databaseName: 'n8ndb'
    adminLogin: 'n8nadmin'
    delegatedSubnetId: persistence.outputs.dbSubnetId
  adminPassword: postgresAdminPassword
  }
  dependsOn: [
    persistence
  ]
}

// App for all tiers
module appBase 'modules/app-base.bicep' = {
  name: 'app'
  params: {
    location: location
    envName: isTry ? (empty(acaEnvironmentName) ? 'env-${environmentName}' : acaEnvironmentName) : envNameSp
    createNewEnvironment: isTry ? createNewEnvironment : true
    image: image
    cpu: 2
    memory: '4Gi'
    // Enable mount only for Small/Prod
    mountEnabled: !isTry
    storageAccountName: !isTry ? persistence.outputs.storageAccountName : ''
    fileShareName: !isTry ? persistence.outputs.fileShareName : ''
    storageAccountKey: !isTry ? persistence.outputs.storageAccountKey : ''
    dbEnabled: isProd
    dbHost: isProd ? postgres.outputs.fqdn : ''
    dbDatabase: isProd ? postgres.outputs.databaseName : ''
    dbUser: isProd ? postgres.outputs.adminLogin : ''
    dbPassword: isProd ? postgres.outputs.adminPassword : ''
  }
  dependsOn: !isTry ? (isProd ? [ persistence, postgres ] : [ persistence ]) : []
}

output AZURE_LOCATION string = location
output AZURE_CONTAINER_APP_NAME string = appBase.outputs.containerAppName
output AZURE_CONTAINER_APP_ENVIRONMENT string = appBase.outputs.environmentName
output CONTAINER_APP_URL string = appBase.outputs.containerAppFqdn
output STORAGE_ACCOUNT string = !isTry ? persistence.outputs.storageAccountName : ''
output FILE_SHARE string = !isTry ? persistence.outputs.fileShareName : ''
output POSTGRES_SERVER string = isProd ? postgres.outputs.serverName : ''
output POSTGRES_FQDN string = isProd ? postgres.outputs.fqdn : ''
output POSTGRES_DB string = isProd ? postgres.outputs.databaseName : ''
output DEPLOYMENT_TIER string = deploymentTier
