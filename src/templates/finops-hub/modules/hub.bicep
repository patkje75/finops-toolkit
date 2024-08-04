// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

//==============================================================================
// Parameters
//==============================================================================

@description('Optional. Name of the hub. Used to ensure unique resource names. Default: "finops-hub".')
param hubName string

@description('Optional. Azure location where all resources should be created. See https://aka.ms/azureregions. Default: (resource group location).')
param location string = resourceGroup().location

@allowed([
  'Premium_LRS'
  'Premium_ZRS'
])
@description('Optional. Storage SKU to use. LRS = Lowest cost, ZRS = High availability. Note Standard SKUs are not available for Data Lake gen2 storage. Allowed: Premium_LRS, Premium_ZRS. Default: Premium_LRS.')
param storageSku string = 'Premium_LRS'

@description('Optional. Tags to apply to all resources. We will also add the cm-resource-parent tag for improved cost roll-ups in Cost Management.')
param tags object = {}

@description('Optional. Tags to apply to resources based on their resource type. Resource type specific tags will be merged with tags for all resources.')
param tagsByResource object = {}

@description('Optional. List of scope IDs to create exports for.')
param exportScopes array

@description('Optional. Indicates whether ingested data should be converted to Parquet. Default: true.')
param convertToParquet bool = true

@description('Optional. Enable telemetry to track anonymous module usage trends, monitor for bugs, and improve future releases.')
param enableDefaultTelemetry bool = true

@description('Optional. Name of the FinOpsHub virtual network.')
param networkName string = 'vnet-finops-hub'

@description('Optional. To use Private Endpoints in an existing virtual network, add target subnet resource Id.')
param subnetResourceId string = ''

@description('Optional. Name of the Storage account for deployment scripts.')
param dsStorageAccountName string = '${toLower(hubName)}stgdsscripts'

@description('Optional. To use Private Endpoints  in an existing virtual network, add target subnet resource Id for the deployment scripts')
param scriptsSubnetResourceId string = ''

@description('Optional. To create networking resources.')
@allowed([
  'Public'
  'Private'
  'PrivateWithExistingNetwork'
])
param networkingOption string = 'Public'

@description('Optional. Address prefix for the FinOpsHub virtual network.')
param networkAddressPrefix string = '10.0.0.0/24'

@description('Optional. Name of the FinOpsHub subnet.')
param networkSubnetName string = 'subnet-finops-hub'

@description('Optional. Address prefix for the created FinOpsHub subnet.')
param networkSubnetPrefix string = cidrSubnet(networkAddressPrefix,24,0)

@description('Optional. Name of the FinOpsHub scripts created subnet.')
param scriptsSubnetName string = 'subnet-finops-hub-scripts'

@description('Optional. Address prefix for the created scripts subnet.')
param scriptsSubnetPrefix string = cidrSubnet(networkAddressPrefix,24,1)


//------------------------------------------------------------------------------
// Variables
//------------------------------------------------------------------------------

// Add cm-resource-parent to group resources in Cost Management
var resourceTags = union(tags, {
    'cm-resource-parent': '${resourceGroup().id}/providers/Microsoft.Cloud/hubs/${hubName}'
  })

// Generate globally unique Data Factory name: 3-63 chars; letters, numbers, non-repeating dashes
var safeHubName = replace(replace(toLower(hubName), '-', ''), '_', '')
var uniqueSuffix = uniqueString(hubName, resourceGroup().id)
var dataFactoryPrefix = '${replace(hubName, '_', '-')}-engine'
var dataFactorySuffix = '-${uniqueSuffix}'
var dataFactoryName = replace('${take(dataFactoryPrefix, 63 - length(dataFactorySuffix))}${dataFactorySuffix}', '--', '-')
var storageAccountName = '${take(safeHubName, 24 - length(uniqueSuffix))}${uniqueSuffix}'

// The last segment of the telemetryId is used to identify this module
var telemetryId = '00f120b5-2007-6120-0000-40b000000000'
var finOpsToolkitVersion = loadTextContent('ftkver.txt')
// Private Endpoints for ADF
var adfPrivateEndpoints = [
  {
    name: 'adf'
    groupIds: [
      'dataFactory'
    ]
  }
  {
    name: 'adf-portal'
    groupIds: [
      'portal'
    ]
  }
]


//==============================================================================
// Resources
//==============================================================================

//------------------------------------------------------------------------------
// Telemetry
// Used to anonymously count the number of times the template has been deployed
// and to track and fix deployment bugs to ensure the highest quality.
// No information about you or your cost data is collected.
//------------------------------------------------------------------------------

resource defaultTelemetry 'Microsoft.Resources/deployments@2022-09-01' = if (enableDefaultTelemetry) {
  name: 'pid-${telemetryId}-${uniqueString(deployment().name, location)}'
  properties: {
    mode: 'Incremental'
    template: {
      '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
      contentVersion: '1.0.0.0'
      metadata: {
        _generator: {
          name: 'FinOps toolkit'
          version: '0.2.1-rc.2'  /////// Revert
        }
      }
      resources: []
    }
  }
}

//------------------------------------------------------------------------------
// Storage account for deployment scripts
//------------------------------------------------------------------------------

// Create managed identity to upload files
resource uploadFilesIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${storageAccountName}_blobManager'
  tags: union(tags, tagsByResource[?'Microsoft.ManagedIdentity/userAssignedIdentities'] ?? {})
  location: location
}

module dsStorageAccount 'br/public:avm/res/storage/storage-account:0.11.0' = if(networkingOption != 'Public' && !empty(subnetResourceId) && !empty(scriptsSubnetResourceId)) {
  name: dsStorageAccountName
  params: {
    name: dsStorageAccountName
    skuName: 'Standard_LRS'
    tags: union(tags, tagsByResource[?'Microsoft.Storage/storageAccounts'] ?? {})
    supportsHttpsTrafficOnly: true
    allowSharedKeyAccess: true
    roleAssignments: [
      {
        roleDefinitionIdOrName: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
        principalId: uploadFilesIdentity.properties.principalId
        principalType: 'ServicePrincipal'
      }
      {
        roleDefinitionIdOrName: 'e40ec5ca-96e0-45a2-b4ff-59039f2c2b59'
        principalId: uploadFilesIdentity.properties.principalId
        principalType: 'ServicePrincipal'
      }
      {
        roleDefinitionIdOrName: '69566ab7-960f-475b-8e7c-b3118f30c6bd'
        principalId: uploadFilesIdentity.properties.principalId
        principalType: 'ServicePrincipal'
      }
      {
        roleDefinitionIdOrName: '69566ab7-960f-475b-8e7c-b3118f30c6bd'
        principalId: dataFactoryScriptsIdentity.properties.principalId
        principalType: 'ServicePrincipal'
      }
    ]
    networkAcls: (networkingOption == 'Public') ? null : {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      virtualNetworkRules: [
        {
          id: (networkingOption == 'PrivateWithExistingNetwork') ? scriptsSubnetResourceId : vnet.outputs.subnetResourceIds[1]
          action: 'Allow'
          state: 'Succeeded'
        }
      ]
    }
  }
}

//------------------------------------------------------------------------------
// ADLSv2 storage account for staging and archive
//------------------------------------------------------------------------------

module storage 'storage.bicep' = {
  name: 'storage'
  params: {
    hubName: hubName
    uniqueSuffix: uniqueSuffix
    sku: storageSku
    location: location
    tags: resourceTags
    tagsByResource: tagsByResource
    exportScopes: exportScopes
    subnetResourceId: subnetResourceId
    scriptsSubnetResourceId: scriptsSubnetResourceId
    userAssignedManagedIdentityResourceId: uploadFilesIdentity.id
    userAssignedManagedIdentityPrincipalId: uploadFilesIdentity.properties.principalId
    dsStorageAccountResourceId : empty(subnetResourceId) ? '' : dsStorageAccount.outputs.resourceId
    networkingOption: networkingOption
    newsubnetResourceId: vnet.outputs.subnetResourceIds[0]
    newScriptsSubnetResourceId: vnet.outputs.subnetResourceIds[1]
  }
}

//------------------------------------------------------------------------------
// Data Factory and pipelines
//------------------------------------------------------------------------------

resource dataFactory 'Microsoft.DataFactory/factories@2018-06-01' = {
  name: dataFactoryName
  location: location
  tags: union(resourceTags, tagsByResource[?'Microsoft.DataFactory/factories'] ?? {})
  identity: { type: 'SystemAssigned' }
  properties: union(
    // Using union() to hide the error that gets surfaced because globalConfigurations is not in the ADF schema yet.
    {
    },
    {
      globalConfigurations: {
        PipelineBillingEnabled: 'true'
      }
      publicNetworkAccess: (networkingOption != 'Public') ? 'Disabled' : 'Enabled'
    })
}

// Create managed identity for data factory operations
resource dataFactoryScriptsIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${storageAccountName}_triggerManager'
  tags: union(tags, tagsByResource[?'Microsoft.ManagedIdentity/userAssignedIdentities'] ?? {})
  location: location
}

module dataFactoryResources 'dataFactory.bicep' = {
  name: 'dataFactoryResources'
  params: {
    dataFactoryName: dataFactoryName
    convertToParquet: convertToParquet
    keyVaultName: keyVault.outputs.name
    storageAccountName: storage.outputs.name
    exportContainerName: storage.outputs.exportContainer
    ingestionContainerName: storage.outputs.ingestionContainer
    location: location
    tags: resourceTags
    tagsByResource: tagsByResource
    subnetResourceId: subnetResourceId
    scriptsSubnetResourceId: scriptsSubnetResourceId
    dsStorageAccountResourceId : empty(subnetResourceId) ? '' : dsStorageAccount.outputs.resourceId
    userAssignedManagedIdentityResourceId: dataFactoryScriptsIdentity.id
    userAssignedManagedIdentityPrincipalId: dataFactoryScriptsIdentity.properties.principalId
    networkingOption: networkingOption
    newsubnetResourceId: vnet.outputs.subnetResourceIds[0]
    newScriptsSubnetResourceId: vnet.outputs.subnetResourceIds[1]
  }
}

//------------------------------------------------------------------------------
// Key Vault for storing secrets
//------------------------------------------------------------------------------

module keyVault 'keyVault.bicep' = {
  name: 'keyVault'
  params: {
    hubName: hubName
    uniqueSuffix: uniqueSuffix
    location: location
    tags: resourceTags
    tagsByResource: tagsByResource
    storageAccountName: storage.outputs.name
    subnetResourceId:!empty(subnetResourceId) ? subnetResourceId : ''
    accessPolicies: [
      {
        objectId: dataFactory.identity.principalId
        tenantId: subscription().tenantId
        permissions: {
          secrets: [
            'get'
          ]
        }
      }
    ]
    networkingOption: networkingOption
    newsubnetResourceId: vnet.outputs.subnetResourceIds[0]
    newScriptsSubnetResourceId: vnet.outputs.subnetResourceIds[1]
  }
}

//------------------------------------------------------------------------------
// Virtual network for private access
//------------------------------------------------------------------------------

module vnet 'br/public:avm/res/network/virtual-network:0.1.8' = if (networkingOption == 'Private') {
  name: networkName
  params: {
    name: networkName
    addressPrefixes: [
      networkAddressPrefix
    ]
    location: location
    tags: union(tags, tagsByResource[?'Microsoft.Network/virtualNetworks'] ?? {})
    subnets: [
      {
        name: networkSubnetName
        addressPrefix: networkSubnetPrefix
      }
      {
        name: scriptsSubnetName
        addressPrefix: scriptsSubnetPrefix
        serviceEndpoints: [
          {
            service: 'Microsoft.Storage'
          }
        ]
        delegations: [
          {
            name: 'Microsoft.ContainerInstance.containerGroups'
            properties: {
              serviceName: 'Microsoft.ContainerInstance/containerGroups'
            }
          }
        ]
      }
    ]
  }
}



//------------------------------------------------------------------------------
// Private Endpoints for ADF
//------------------------------------------------------------------------------

resource privateEndpointADF 'Microsoft.Network/privateEndpoints@2022-05-01' = [for (privateEndpoint,index) in adfPrivateEndpoints: if(networkingOption != 'Public')  {
  name: 'pve-${privateEndpoint.name}-${dataFactory.name}'
  location: location
  properties: {

    customNetworkInterfaceName: 'nic-${privateEndpoint.name}-${dataFactory.name}'
    privateLinkServiceConnections: [
      {
        name: 'pve-${privateEndpoint.name}-${dataFactory.name}'
        properties: {
          privateLinkServiceId: dataFactory.id
          groupIds: privateEndpoint.groupIds
        }
      }
    ]
    subnet: {
      id: networkingOption == 'PrivateWithExistingNetwork' ? subnetResourceId : vnet.outputs.subnetResourceIds[0]
      properties: {
        privateEndpointNetworkPolicies: 'Enabled'
      }

    }
  }
}]

//------------------------------------------------------------------------------
// Private DNS zones for ADF
//------------------------------------------------------------------------------

resource privateDNSZoneDataFactory 'Microsoft.Network/privateDnsZones@2020-06-01' = if(networkingOption == 'Private'){
  name: 'privatelink.datafactory.azure.net'
  location: 'global'

  resource virtualNetworkLinks 'virtualNetworkLinks@2020-06-01' = {
    name: '${vnet.name}-dataFactoryLink'
    location: 'global'
    properties: {
      virtualNetwork: {
        id: resourceId('Microsoft.Network/virtualNetworks', vnet.name)
      }
      registrationEnabled: false
    }
  }
}

resource privateDNSZoneDataFactoryPortal 'Microsoft.Network/privateDnsZones@2020-06-01' = if(networkingOption == 'Private'){
  name: 'privatelink.adf.azure.com'
  location: 'global'

  resource virtualNetworkLinks 'virtualNetworkLinks@2020-06-01' = {
    name: '${vnet.name}-dataFactoryPortalLink'
    location: 'global'
    properties: {
      virtualNetwork: {
        id: resourceId('Microsoft.Network/virtualNetworks', vnet.name)
      }
      registrationEnabled: true
    }
  }
}

//==============================================================================
// Outputs
//==============================================================================

@description('Name of the deployed hub instance.')
output name string = hubName

@description('Azure resource location resources were deployed to.')
output location string = location

@description('Name of the Data Factory.')
output dataFactorytName string = dataFactory.name

@description('Resource ID of the storage account created for the hub instance. This must be used when creating the Cost Management export.')
output storageAccountId string = storage.outputs.storageAccountId

@description('Name of the storage account created for the hub instance. This must be used when connecting FinOps toolkit Power BI reports to your data.')
output storageAccountName string = storage.outputs.name

@description('URL to use when connecting custom Power BI reports to your data.')
output storageUrlForPowerBI string = 'https://${storage.outputs.name}.dfs.${environment().suffixes.storage}/${storage.outputs.ingestionContainer}'
