param location string = resourceGroup().location
param utcValue string = utcNow()
param poolName string = 'containerapp-adoagent'
param adourl string = 
param token string = '
param imagename string = 'adoagent:1.0'
param managedenvname string = 'cnapps'

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
  name: managedenvname
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey:law.listkeys().primarySharedKey

      }
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
    adminUserEnabled: false
  }
}
// Reference existing managed identity with Owner role, due to write assignments needed for COntainer Registry.

resource usrmi 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: 'usrmi'
}

resource law 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'law-${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
}}

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
    azCliVersion: '2.50.0'
    retentionInterval: 'P1D'
    timeout: 'PT30M'
    arguments: '${containerregistry.name} ${imagename}'
    scriptContent: '''
    az login --identity
    az acr build --registry $1 --image $2  --file Dockerfile.azure-pipelines https://github.com/lukemurraynz/containerapps-selfhosted-agent.git
    '''
    cleanupPreference: 'OnSuccess'
  }

}

resource arcplaceholder 'Microsoft.Resources/deploymentScripts@2020-10-01' = {
  name: 'arcplaceholder'
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
    azCliVersion: '2.50.0'
    retentionInterval: 'P1D'
    timeout: 'PT30M'
    arguments: '${containerregistry.name} ${imagename} ${poolName} ${resourceGroup().name} ${adourl} ${token} ${managedenvname} ${usrmi.id}'
    scriptContent: '''
    az login --identity
    az extension add --name containerapp --upgrade --only-show-errors
    az containerapp job create -n 'placeholder' -g $4 --environment $7 --trigger-type Manual --replica-timeout 300 --replica-retry-limit 1 --replica-completion-count 1 --parallelism 1 --image "$1.azurecr.io/$2" --cpu "2.0" --memory "4Gi" --secrets "personal-access-token=$6" "organization-url=$5" --env-vars "AZP_TOKEN=secretref:personal-access-token" "AZP_URL=secretref:organization-url" "AZP_POOL=$AZP_POOL" "AZP_PLACEHOLDER=1" "AZP_AGENT_NAME=placeholder-agent" --registry-server "$1.azurecr.io" --registry-identity "$8"    
    '''
    cleanupPreference: 'OnSuccess'
  }
  dependsOn: [
    arcbuild
    cnapps
  ]

}

resource adoagentjob 'Microsoft.App/jobs@2023-05-01' = {
  name: 'adoagentjob'
  location: location
  tags: tags

  properties: {
    
    environmentId: cnapps.id

    configuration: {
      triggerType: 'Event'

      secrets: [
        {
          name: 'personal-access-token'
          value: token
        }
        {
          name: 'organization-url'
          value: adourl
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
                poolName: poolName
                targetPipelinesQueueLength: '1'
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
          identity: usrmi.id
        }
      ]

    }
    template: {
      containers: [
        {
          image: '${containerregistry.properties.loginServer}/adoagent:1.0'
          name: 'adoagent'
          env: [
            {
              name: 'AZP_TOKEN'
              secretRef: 'personal-access-token'
            }
            {
              name: 'AZP_URL'
              secretRef: 'organization-url'
            }
            {
              name: 'AZP_POOL'
              value: poolName
            }

          ]
          resources: {
            cpu: 2
            memory: '4Gi'
          }
        }
      ]
    }

  }
dependsOn: [
  arcplaceholder
]
}


