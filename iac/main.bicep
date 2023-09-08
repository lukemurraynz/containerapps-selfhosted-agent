param location string = resourceGroup().location
param poolName string = 'containerapp-adoagent'
param adourl string = ''
@secure()
param token string = ''
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
        name: 'sharedservices'
        properties: {
          addressPrefix: '10.0.0.0/24'
        }
      }
      {
        name: 'containerappssnet'
        properties: {
          addressPrefix: '10.0.2.0/23'

        }

      }
    ]
  }
}

resource keyvault 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: 'keyvault-ado'
  location: location
  tags: tags

  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenant().tenantId
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: []
    }
    enableRbacAuthorization: true
    accessPolicies: []
    publicNetworkAccess: 'Disabled'
    enableSoftDelete: false
    // Change SoftDelete to True for Production
    enabledForTemplateDeployment: true
  }

}

resource kvtokensecret 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  name: 'personal-access-token'
  parent: keyvault
  properties: {
    value: token
  }
}
resource kvadourlsecret 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  name: 'organization-url'
  parent: keyvault
  properties: {
    value: adourl
  }
}
resource kvprivatelink 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  name: 'pe-${(keyvault.name)}'
  location: location
  tags: tags
  properties: {
    privateLinkServiceConnections: [
      {
        name: 'keyvault'
        properties: {
          privateLinkServiceId: keyvault.id
          groupIds: [ 'vault' ]
        }
      }
    ]
    subnet: {
      id: containerappsspokevnet.properties.subnets[0].id
    }
  }
}



resource keyvaultdnszone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'

}

resource keyvaultprivatednszonegrp 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-04-01' = {
name: keyvaultdnszone.name
parent: kvprivatelink
properties: {
  privateDnsZoneConfigs: [
    {
      name: 'keyvault'
      properties: {
        privateDnsZoneId: keyvaultdnszone.id
        //privateDnsZoneId: keyvault.id
      }
    }
  ]
}
}
 

resource keyVaultPrivateDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: '${uniqueString(keyvault.id)}'
  parent: keyvaultdnszone
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: containerappsspokevnet.id
    }
  }
}


resource aarecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  name: keyvault.name
parent: keyvaultdnszone
  properties: {
    aRecords: [
      {
        ipv4Address: kvprivatelink.properties.customDnsConfigs[0].ipAddresses[0]
   }
   ]
    ttl: 300
  }
}


resource cnapps 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: managedenvname
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'azure-monitor'
    }
    vnetConfiguration: {
      infrastructureSubnetId: containerappsspokevnet.properties.subnets[1].id
      internal: true

    }
    zoneRedundant: true
  }
}

resource cnappsdiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'cnappsdiag'
  scope: cnapps
  properties: {
    logs: [

      {
        category: 'audit'
        enabled: true
        retentionPolicy: {
          enabled: true
          days: 30
        }
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
        retentionPolicy: {
          enabled: true
          days: 30
        }
      }
    ]
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
    retentionInDays: 30
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  } }

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
    az containerapp job create -n 'placeholder' -g $4 --environment $7 --trigger-type Manual --replica-timeout 300 --replica-retry-limit 1 --replica-completion-count 1 --parallelism 1 --image "$1.azurecr.io/$2" --cpu "2.0" --memory "4Gi" --secrets "personal-access-token=$6" "organization-url=$5" --env-vars "AZP_TOKEN=secretref:personal-access-token" "AZP_URL=secretref:organization-url" "AZP_POOL=$3" "AZP_PLACEHOLDER=1" "AZP_AGENT_NAME=placeholder-agent" --registry-server "$1.azurecr.io" --registry-identity "$8"    
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
          keyVaultUrl: kvtokensecret.properties.secretUri
          identity: usrmi.id
        }
        {
          name: 'organization-url'
          keyVaultUrl: kvadourlsecret.properties.secretUri
          identity: usrmi.id
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

