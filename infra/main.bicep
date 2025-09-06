targetScope = 'resourceGroup'

@minLength(1)
@maxLength(64)
@description('Name used as prefix for all resources')
param environmentName string

@description('Primary location for all resources')
param location string = 'centralus'

@description('(Optional) existing ACA environment name; blank = create new one')
param acaEnvironmentName string = ''

@description('n8n Docker image')
param image string = 'docker.n8n.io/n8nio/n8n'

var createNewEnvironment = empty(acaEnvironmentName)

// Directly call module (RG already exists because azd creates it)
module n8n 'n8n-on-aca-storage.bicep' = {
  name: 'n8n-deployment'
  params: {
    location: location
    envName: empty(acaEnvironmentName) ? 'env-${environmentName}' : acaEnvironmentName
    image: image
    createNewEnvironment: createNewEnvironment
  }
}

output AZURE_LOCATION string = location
output AZURE_CONTAINER_APP_NAME string = n8n.outputs.containerAppName
output AZURE_CONTAINER_APP_ENVIRONMENT string = n8n.outputs.environmentName
output CONTAINER_APP_URL string = n8n.outputs.containerAppFqdn
