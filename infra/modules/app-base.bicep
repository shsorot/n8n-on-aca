@description('Location for resources')
param location string
@description('ACA managed environment name')
param envName string
@description('Create new managed environment')
param createNewEnvironment bool = true
@description('n8n container image')
param image string = 'docker.n8n.io/n8nio/n8n'
@description('CPU cores')
param cpu int = 2
@description('Memory (Gi)')
@allowed([ '4Gi' ])
param memory string = '4Gi'
@description('Enable Azure File mount')
param mountEnabled bool = false
@description('Deployment tier label for diagnostics')
param deploymentTier string = 'Try'
@description('Storage account name for file share (required if mountEnabled)')
param storageAccountName string = ''
@description('File share name (required if mountEnabled)')
param fileShareName string = ''
@secure()
@description('Storage account key (required if mountEnabled)')
param storageAccountKey string = ''
@description('Enable Postgres DB integration')
param dbEnabled bool = false
@description('DB host FQDN')
param dbHost string = ''
@description('DB name')
param dbDatabase string = ''
@description('DB user')
param dbUser string = ''
@secure()
@description('DB password')
param dbPassword string = ''
@description('ACA subnet resource ID (optional for VNet integration)')
param acaSubnetId string = ''

var wpConsumptionName = 'Consumption'
var encryptionKey = uniqueString(resourceGroup().id, 'n8n-encryption-key')
var basicAuthPassword = uniqueString(resourceGroup().id, 'n8n-basic-auth-pass')
var suffix = toLower(substring(uniqueString(resourceGroup().id, envName, image), 0, 5))
var appName = 'n8n-${suffix}'

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = if (createNewEnvironment) {
  name: envName
  location: location
  properties: {
    workloadProfiles: [
      {
        name: wpConsumptionName
        workloadProfileType: 'Consumption'
      }
    ]
    vnetConfiguration: !empty(acaSubnetId) ? {
      infrastructureSubnetId: acaSubnetId
    } : null
  }
}

resource existingEnv 'Microsoft.App/managedEnvironments@2024-03-01' existing = if (!createNewEnvironment) {
  name: envName
}

var effectiveEnvId = createNewEnvironment ? env.id : existingEnv.id
var effectiveEnvDomain = createNewEnvironment ? env.properties.defaultDomain : existingEnv.properties.defaultDomain
var fqdnBase = '${appName}.${effectiveEnvDomain}'

// Core environment variables
var coreEnv = [
  {
    name: 'N8N_ENCRYPTION_KEY'
    value: encryptionKey
  }
  {
    name: 'GENERIC_TIMEZONE'
    value: 'UTC'
  }
  {
    name: 'WEBHOOK_URL'
    value: 'https://${fqdnBase}'
  }
  {
    name: 'TRUST_PROXY'
    value: 'true'
  }
  {
    name: 'N8N_BASIC_AUTH_ACTIVE'
    value: 'true'
  }
  {
    name: 'N8N_BASIC_AUTH_USER'
    value: 'n8nuser'
  }
  {
    name: 'N8N_BASIC_AUTH_PASSWORD'
    value: basicAuthPassword
  }
  {
    name: 'N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS'
    value: 'false'
  }
  {
    name: 'DEPLOYMENT_TIER'
    value: deploymentTier
  }
]

var dbEnv = dbEnabled ? [
  {
    name: 'DB_TYPE'
    value: 'postgresdb'
  }
  {
    name: 'DB_POSTGRESDB_HOST'
    value: dbHost
  }
  {
    name: 'DB_POSTGRESDB_PORT'
    value: '5432'
  }
  {
    name: 'DB_POSTGRESDB_DATABASE'
    value: dbDatabase
  }
  {
    name: 'DB_POSTGRESDB_USER'
    value: dbUser
  }
  {
    name: 'DB_POSTGRESDB_PASSWORD'
    secretRef: 'db-password'
  }
  {
    name: 'DB_POSTGRESDB_SCHEMA'
    value: 'n8n'
  }
  {
    name: 'DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED'
    value: 'false'
  }
] : []

var allEnv = concat(coreEnv, dbEnv)

// Secrets array (avoid nested conditional concat directly inline)
var storageSecret = mountEnabled ? [ {
  name: 'storage-key'
  value: storageAccountKey
} ] : []
var dbSecret = dbEnabled ? [ {
  name: 'db-password'
  value: dbPassword
} ] : []
var allSecrets = concat(storageSecret, dbSecret)

// Volumes definition
var volumesArr = mountEnabled ? [ {
  name: 'n8n-data'
  storageType: 'AzureFile'
  storageName: 'n8n-storage'
} ] : []

// Dependency arrays
// (removed) direct dependency resolution inline below

resource app 'Microsoft.App/containerApps@2025-02-02-preview' = {
  name: appName
  location: location
  dependsOn: createNewEnvironment
    ? (mountEnabled ? [ env, managedStorageNew ] : [ env ])
    : (mountEnabled ? [ managedStorageExisting ] : [])
    properties: {
      managedEnvironmentId: effectiveEnvId
      workloadProfileName: wpConsumptionName
      configuration: {
        ingress: {
          external: true
          targetPort: 5678
          transport: 'http'
        }
        secrets: allSecrets
      }
      template: {
        volumes: mountEnabled ? [ {
          name: 'n8n-data'
          storageType: 'NfsAzureFile'
          storageName: 'n8n-storage'
          mountOptions: 'vers=4.1'
        } ] : []
        containers: [
        {
          name: 'n8n'
          image: image
          env: allEnv
          resources: {
            cpu: cpu
            memory: memory
          }
          volumeMounts: mountEnabled ? [ {
            volumeName: 'n8n-data'
            mountPath: '/home/node/.n8n'
          } ] : []
        }
        ]
        scale: {
          minReplicas: 1
          maxReplicas: 1
        }
      }
    }
}

// Storage definition resource when mountEnabled
// Storage for newly created env
resource managedStorageNew 'Microsoft.App/managedEnvironments/storages@2025-02-02-preview' = if (mountEnabled && createNewEnvironment) {
  name: 'n8n-storage'
  parent: env
  properties: {
    nfsAzureFile: {
      server: '${storageAccountName}.privatelink.file.core.windows.net'
  shareName: '/${storageAccountName}/${fileShareName}'
      accessMode: 'ReadWrite'
    }
  }
}

// Storage for existing env reference
resource managedStorageExisting 'Microsoft.App/managedEnvironments/storages@2025-02-02-preview' = if (mountEnabled && !createNewEnvironment) {
  name: 'n8n-storage'
  parent: existingEnv
  properties: {
    nfsAzureFile: {
      server: '${storageAccountName}.privatelink.file.core.windows.net'
  shareName: '/${storageAccountName}/${fileShareName}'
      accessMode: 'ReadWrite'
    }
  }
}

output containerAppName string = app.name
output environmentName string = envName
output containerAppFqdn string = 'https://${fqdnBase}'
output containerAppRawFqdn string = fqdnBase
@secure()
output basicAuthPassword string = basicAuthPassword
