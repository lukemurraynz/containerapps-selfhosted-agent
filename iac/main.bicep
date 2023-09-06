param location string = resourceGroup().location
param utcValue string = utcNow()

param tags object = {
  environment: 'Production'
  createdBy: 'Luke Murray'
}

resource containerappsspokevnet 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: 'containerappsspokevnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.0.0.0/16' ]
    }
    subnets: [
      {
        name: 'containerappssnet'
        properties: {
          addressPrefix: '10.0.0.0/23'

        }
      }
    ]
  }
}

resource cnapps 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: 'cnapps'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: null
      logAnalyticsConfiguration: null
    }
    vnetConfiguration: {
      infrastructureSubnetId: containerappsspokevnet.properties.subnets[0].id
      internal: true
    }
    zoneRedundant: true
  }
}

resource containerregistry 'Microsoft.ContainerRegistry/registries@2023-06-01-preview' = {
  name: 'registrycontainerluke'
  location: location
  
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    networkRuleBypassOptions: 'AzureServices'
    adminUserEnabled: true
  }
}
// Reference existing managed identity with contributor role.

resource usrmi 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing =  {
name: 'usrmi'
}


resource arcbuild 'Microsoft.Resources/deploymentScripts@2020-10-01' = {
  name: 'acrbuild'
  location: location
  tags: tags
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${usrmi.id}': {}
    }
  }

  properties: {
    azCliVersion: '2.9.1'
    retentionInterval: 'P1D'
    timeout: 'PT30M'
    arguments: '${containerregistry.name}'
    scriptContent: '''
    az login --identity
    az acr build --registry $1 --image adoagent:1.0  --file Dockerfile.azure-pipelines https://github.com/lukemurraynz/containerapps-selfhosted-agent.git
    '''
    cleanupPreference: 'OnSuccess'
  }

}

resource keyvault 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: 'keyvault'
  location:location
  properties: {
    sku: {
      family:  'A'
      name:  'standard'
    }
    tenantId:  subscription().tenantId
  }
}

resource adoagentjob 'Microsoft.App/jobs@2023-05-01' = {
  name: 'adoagentjob'
  location: location

  properties: {
    environmentId: cnapps.id
    configuration: {
      triggerType: 'Event'

      secrets: [
        {
          name: 'AZP_TOKEN'
        }
        {
          name: 'AZP_URL'
        }
        {
        name: '${containerregistry.name}'
        value: '${containerregistry.id}'
        }
      ]
      replicaTimeout: 1800
      replicaRetryLimit: 1
      eventTriggerConfig: {
        replicaCompletionCount: 1
        parallelism: 1
        scale: {
          minExecutions: 0
          maxExecutions: 10
          pollingInterval: 30
          rules: [
            {
              name: 'azure-pipelines'
              type: 'azure-pipelines'

              // https://keda.sh/docs/2.11/scalers/azure-pipelines/
              metadata: {
              }
              auth: [
                {
                  secretRef: 'AZP_TOKEN'
                  triggerParameter: 'personalAccessToken'
                }
                {
                  secretRef: 'AZP_URL'
                  triggerParameter: 'organizationURL'
                }
              ]
            }
          ]
        }
      }
      registries: [
        {
          server: containerregistry.properties.loginServer
          username: 'lukecontregistry'
          passwordSecretRef: 'lukecontregistryazurecrio-lukecontregistry'
        }
      ]
      
    }
    

    }

  }


