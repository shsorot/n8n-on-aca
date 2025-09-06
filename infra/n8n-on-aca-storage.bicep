@description('Azure location')
param location string = 'centralus'

@description('Container Apps Environment name')
param envName string

@description('n8n image')
param image string = 'docker.n8n.io/n8nio/n8n'

@description('Create new Container Apps Environment')
param createNewEnvironment bool = true

@secure()
@description('PostgreSQL admin password (auto-generated if not provided)')
param postgresAdminPassword string = replace(newGuid(), '-', '')

var suffix = toLower(substring(uniqueString(resourceGroup().id), 0, 4))
var appName = 'n8n-app-${suffix}'
var wpConsumptionName = 'Consumption'

// PostgreSQL variables
var postgresServerName = 'n8n-postgres-${suffix}'
var postgresAdminLogin = 'n8nadmin'
var postgresDatabaseName = 'n8ndb'

// n8n configuration
var encryptionKey = uniqueString(resourceGroup().id, 'n8n-encryption-key')
var basicAuthPassword = uniqueString(resourceGroup().id, 'n8n-basic-auth-pass')

// PostgreSQL Flexible Server
resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2023-12-01-preview' = {
  name: postgresServerName
  location: location
  sku: {
    name: 'Standard_B1ms'  // Smallest available SKU
    tier: 'Burstable'
  }
  properties: {
    administratorLogin: postgresAdminLogin
    administratorLoginPassword: postgresAdminPassword
    version: '15'
    storage: {
      storageSizeGB: 32  // Minimum storage
      tier: 'P4'
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
// Derive FQDN instead of using any-typed properties
var postgresHost = '${postgresServer.name}.postgres.database.azure.com'

// PostgreSQL Database
resource postgresDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-12-01-preview' = {
  parent: postgresServer
  name: postgresDatabaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// PostgreSQL Firewall rule to allow Azure services
resource postgresFirewallRule 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-12-01-preview' = {
  parent: postgresServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// Conditional environment resources
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
  }
}

// Reference existing Container Apps Environment (if createNewEnvironment is false)
resource existingEnv 'Microsoft.App/managedEnvironments@2024-03-01' existing = if (!createNewEnvironment) {
  name: envName
}

var environmentName = envName
var environmentDomain = createNewEnvironment ? env.properties.defaultDomain : existingEnv.properties.defaultDomain
var fqdnBase = '${appName}.${environmentDomain}'

// Container App using Consumption profile with PostgreSQL
resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  properties: {
    managedEnvironmentId: createNewEnvironment ? env.id : existingEnv.id
    workloadProfileName: wpConsumptionName
    configuration: {
      ingress: {
        external: true
        targetPort: 5678
        transport: 'http'
      }
    }
    template: {
      containers: [
        {
          name: 'n8n'
          image: image
          env: [
            {
              name: 'DB_TYPE'
              value: 'postgresdb'
            }
            {
              name: 'DB_POSTGRESDB_HOST'
              value: postgresHost
            }
            {
              name: 'DB_POSTGRESDB_PORT'
              value: '5432'
            }
            {
              name: 'DB_POSTGRESDB_DATABASE'
              value: postgresDatabaseName
            }
            {
              name: 'DB_POSTGRESDB_USER'
              value: postgresAdminLogin
            }
            {
              name: 'DB_POSTGRESDB_PASSWORD'
              value: postgresAdminPassword
            }
            {
              name: 'DB_POSTGRESDB_SCHEMA'
              value: 'n8n'
            }
            {
              name: 'N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS'
              value: 'false'
            }
            {
              name: 'N8N_ENCRYPTION_KEY'
              value: encryptionKey
            }
            {
              name: 'GENERIC_TIMEZONE'
              value: 'America/New_York'
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
          ]
          resources: {
            cpu: 2
            memory: '4Gi'
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
  dependsOn: [
    postgresDatabase
    postgresFirewallRule
  ]
}

output environmentName string = environmentName
output containerAppName string = app.name
output containerAppFqdn string = 'https://${fqdnBase}'
output containerAppRawFqdn string = fqdnBase
output postgresServerName string = postgresServer.name
output postgresDatabaseName string = postgresDatabaseName
@secure()
output basicAuthPassword string = basicAuthPassword
@secure()
output postgresAdminPassword string = postgresAdminPassword