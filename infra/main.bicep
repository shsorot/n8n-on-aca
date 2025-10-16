targetScope = 'resourceGroup'

@minLength(1)
@maxLength(64)
@description('Name used as prefix for all resources')
param environmentName string

@description('Primary location for all resources')
param location string = 'centralus'

@description('Deployment tier: Try | Small | Production (must be provided)')
@allowed([
  'Try'
  'Small'
  'Production'
])
param tier string

@description('(Try tier only) existing ACA environment name; blank = create new one')
param acaEnvironmentName string = ''

@description('n8n Docker image')
param image string = 'docker.n8n.io/n8nio/n8n'
@description('Use Azure Managed File Share (Microsoft.FileShares) instead of traditional Storage Account')
param useManagedFileShare bool = true

// Tier flags
var isTry = tier == 'Try'
var isProd = tier == 'Production'

// Try tier uses app-base directly with no persistence or database
// Determine whether to create a new ACA environment
var createNewEnvironmentTry = isTry && empty(acaEnvironmentName)
var createNewEnvironmentNonTry = !isTry && empty(acaEnvironmentName)

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
    useManagedFileShare: useManagedFileShare
    enablePrivateEndpoints: true
  }
}// Postgres for Production only
module postgres 'modules/postgres-private.bicep' = if (isProd) {
  name: 'postgres'
  params: {
    location: location
    serverName: pgServerName
    databaseName: 'n8ndb'
    adminLogin: 'n8nadmin'
    delegatedSubnetId: persistence!.outputs.dbSubnetId
    adminPassword: postgresAdminPassword
    privateDnsZoneId: persistence!.outputs.postgresPrivateDnsZoneId
  }
}

// App for all tiers
module appBase 'modules/app-base.bicep' = {
  name: 'app'
  params: {
    location: location
    envName: isTry
      ? (empty(acaEnvironmentName) ? 'env-${environmentName}' : acaEnvironmentName)
      : (empty(acaEnvironmentName) ? envNameSp : acaEnvironmentName)
    createNewEnvironment: isTry ? createNewEnvironmentTry : createNewEnvironmentNonTry
    image: image
    cpu: 2
    memory: '4Gi'
    deploymentTier: tier
    mountEnabled: !isTry
    useManagedFileShare: useManagedFileShare
    storageAccountName: isTry ? '' : persistence!.outputs.storageAccountName
    fileShareName: isTry ? '' : persistence!.outputs.fileShareName
    fileShareMountPath: isTry ? '' : persistence!.outputs.fileShareMountPath

    dbEnabled: isProd
    dbHost: isProd ? postgres!.outputs.fqdn : ''
    dbDatabase: isProd ? postgres!.outputs.databaseName : ''
    dbUser: isProd ? postgres!.outputs.adminLogin : ''
    dbPassword: postgresAdminPassword
    acaSubnetId: isTry ? '' : persistence!.outputs.acaSubnetId
  }
  dependsOn: !isTry ? (isProd ? [ persistence, postgres ] : [ persistence ]) : []
}

output AZURE_LOCATION string = location
output AZURE_CONTAINER_APP_NAME string = appBase.outputs.containerAppName
output AZURE_CONTAINER_APP_ENVIRONMENT string = appBase.outputs.environmentName
output CONTAINER_APP_URL string = appBase.outputs.containerAppFqdn
output STORAGE_ACCOUNT string = !isTry ? persistence!.outputs.storageAccountName : ''
output FILE_SHARE string = !isTry ? persistence!.outputs.fileShareName : ''
output FILE_SHARE_MOUNT_PATH string = !isTry ? persistence!.outputs.fileShareMountPath : ''
output STORAGE_TYPE string = useManagedFileShare ? 'Managed File Share' : 'Storage Account'
output POSTGRES_SERVER string = isProd ? postgres!.outputs.serverName : ''
output POSTGRES_FQDN string = isProd ? postgres!.outputs.fqdn : ''
output POSTGRES_DB string = isProd ? postgres!.outputs.databaseName : ''
output _diagnosticDeploymentTierParam string = tier
