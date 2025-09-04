targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the environment used as prefix for all resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
param location string = 'northeurope'

@description('Resource group name (leave empty to create new one)')
param resourceGroupName string = ''

@description('Container Apps Environment name (leave empty to create new one)')
param acaEnvironmentName string = ''

@description('n8n Docker image')
param image string = 'docker.n8n.io/n8nio/n8n'

@description('Create new Container Apps Environment')
param createNewEnvironment bool = true

// Determine resource group name
var rgName = empty(resourceGroupName) ? 'rg-${environmentName}' : resourceGroupName

// Determine environment name
var envName = empty(acaEnvironmentName) ? 'env-${environmentName}' : acaEnvironmentName

// Create resource group only if name wasn't provided
resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = if (empty(resourceGroupName)) {
  name: rgName
  location: location
}

// Reference existing resource group if name was provided
resource existingResourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' existing = if (!empty(resourceGroupName)) {
  name: rgName
}

module n8n 'infra/n8n-on-aca-storage.bicep' = {
  name: 'n8n-deployment'
  scope: empty(resourceGroupName) ? resourceGroup : existingResourceGroup
  params: {
    location: location
    resourceGroupName: rgName
    envName: envName
    image: image
    createNewEnvironment: createNewEnvironment
  }
}

output AZURE_LOCATION string = location
output AZURE_RESOURCE_GROUP string = rgName
//output AZURE_CONTAINER_APP_NAME string = n8n.outputs.containerAppName
//output AZURE_CONTAINER_APP_ENVIRONMENT string = n8n.outputs.environmentName
//output AZURE_STORAGE_ACCOUNT string = n8n.outputs.standardStorageAccount
//output CONTAINER_APP_URL string = 'https://${n8n.outputs.containerAppFqdn}'
