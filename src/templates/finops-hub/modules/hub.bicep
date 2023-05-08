//------------------------------------------------------------------------------
// Parameters
//------------------------------------------------------------------------------

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

// Generate unique storage account name
var storageAccountSuffix = 'store'
var storageAccountName = '${substring(replace(toLower(hubName), '-', ''), 0, 24 - length(storageAccountSuffix))}${storageAccountSuffix}'
var containerNames = [ 'config', 'ms-cm-exports', 'ingestion' ]

// Data factory naming requirements: Min 3, Max 63, can only contain letters, numbers and non-repeating dashes 
var dataFactorySuffix = '-engine'
var dataFactoryName = '${take(hubName, 63 - length(dataFactorySuffix))}${dataFactorySuffix}'

@description('Optional. Tags to apply to all resources. We will also add the cm-resource-parent tag for improved cost roll-ups in Cost Management.')
param tags object = {}

@description('Optional. List of scope IDs to create exports for.')
param exportScopes array

@description('Optional. Number of days of cost data to retain in the ms-cm-exports container. Default: 0.')
param exportRetentionInDays int = 0

@description('Optional. Number of months of cost data to retain in the ingestion container. Default: 13.')
param ingestionRetentionInMonths int = 13

@description('Optional. Enable telemetry to track anonymous module usage trends, monitor for bugs, and improve future releases.')
param enableDefaultTelemetry bool = true

//------------------------------------------------------------------------------
// Variables
//------------------------------------------------------------------------------

// Generate unique storage account name
var lowerHubName = replace(toLower(hubName), '-', '')
var storageAccountSuffix = 'store'
var storageAccountName = '${substring(lowerHubName, 0, 24 - length(storageAccountSuffix))}${storageAccountSuffix}'

// Data factory naming requirements: Min 3, Max 63, can only contain letters, numbers and non-repeating dashes 
var dataFactorySuffix = '-engine'
var dataFactoryName = '${take(hubName, 63 - length(dataFactorySuffix))}${dataFactorySuffix}'

// Generate unique KeyVault name
var keyVaultSuffixSuffix = 'vault'
var keyVaultName = '${substring(lowerHubName, 0, 24 - length(keyVaultSuffixSuffix))}${keyVaultSuffixSuffix}'
var keyVaultUri = 'https://${keyVaultName}${environment().suffixes.keyvaultDns}/'

var resourceTags = union(tags, {
    'cm-resource-parent': '${resourceGroup().id}/providers/Microsoft.Cloud/hubs/${hubName}'
  })

// The last segment of the telemetryId is used to identify this module
var telemetryId = '00f120b5-2007-6120-0000-40b000000000'
var finOpsToolkitVersion = '0.0.1'

//------------------------------------------------------------------------------
// Resources
//------------------------------------------------------------------------------

// Telemetry used anonymously to count the number of times the template has been deployed.
// No information about you or your cost data is collected.
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
          version: finOpsToolkitVersion
        }
      }
      resources: []
    }
  }
}

// ADLSv2 storage account for staging and archive
resource storageAccount 'Microsoft.Storage/storageAccounts@2021-08-01' = {
    name: storageAccountName
    location: location
  sku: {
    name: storageSku
  }
  kind: 'BlockBlobStorage'
  properties: {
    supportsHttpsTrafficOnly: true
    isHnsEnabled: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
}
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2021-06-01' = {
  parent: storageAccount
  name: 'default'
  }

resource configContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2021-06-01' =  {
  parent: blobService
  name: 'config'
  properties: {
    publicAccess: 'None'
    metadata: {}
}
}

resource exportContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2021-06-01' =  {
  parent: blobService
  name: 'msexports'
  properties: {
    publicAccess: 'None'
    metadata: {}
}
}

resource ingestionContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2021-06-01' =  {
  parent: blobService
  name: 'ingestion'
  properties: {
    publicAccess: 'None'
    metadata: {}
  }
}

resource uploadSettingsJson 'Microsoft.Resources/deploymentScripts@2020-10-01' = {
  name: '${dataFactoryName}_${configContainer.name}_updateSettings'
  kind: 'AzurePowerShell'
  location: location
  properties: {
    azPowerShellVersion: '8.0'
    retentionInterval: 'PT1H'
    environmentVariables: [
      {
        name: 'exportScopes'
        value: join(exportScopes, '|')
      }
      {
        name: 'exportRetentionInDays'
        value: string(exportRetentionInDays)
      }
      {
        name: 'ingestionRetentionInMonths'
        value: string(ingestionRetentionInMonths)
      }
      {
        name: 'storageAccountKey'
        value: storageAccount.listKeys().keys[0].value
      }
      {
        name: 'storageAccountName'
        value: storageAccountName
      }
    ]
    scriptContent: loadTextContent('./scripts/Copy-FileToAzureBlob.ps1')
  }
}

// Key Vault for storing secrets
module keyVault 'Microsoft.KeyVault/vaults/deploy.bicep' = {
  name: 'keyVault'
  dependsOn: [
    dataFactory
  ]
  params: {
    name: keyVaultName
    location: location
    tags: resourceTags
    enablePurgeProtection: false
    accessPolicies: [
      {
        objectId: dataFactory.outputs.systemAssignedPrincipalId
        tenantId: subscription().tenantId
        permissions: {
          secrets: [
            'get'
          ]
        }
      }
    ]
  }
}

module keyVaultSecret 'secrets/storageaccountsecret.bicep' = {
  name: 'keyVaultSecret'
  dependsOn: [
    storageAccount
    keyVault
  ]
  params: {
    keyVaultName: keyVaultName
    storageAccountName: storageAccountName
    secretName: storageAccountName
  }
}

// Azure Data Factory and Pipelines
module dataFactory 'Microsoft.DataFactory/factories/deploy.bicep' = {
  name: 'dataFactory'
  params: {
    name: dataFactoryName
    location: location
    tags: resourceTags
    systemAssignedIdentity: true
  }
}

module linkedService_keyVault 'linkedservices/linkedservice.bicep' = {
  name: 'linkedService_keyVault'
  dependsOn: [
    dataFactory
    keyVaultSecret
  ]
  params: {
    dataFactoryName: dataFactoryName
    linkedServiceName: keyVaultName
    linkedServiceType: 'AzureKeyVault'
    linkedServiceTypeProperties:  {
      baseUrl: keyVaultUri
    }
  }
}

module linkedService_storageAccount 'linkedservices/linkedservice.bicep' = {
  name: 'linkedService_storageAccount'
  dependsOn: [
    dataFactory
    linkedService_keyVault
  ]
  params: {
    dataFactoryName: dataFactoryName
    linkedServiceName: storageAccountName
    linkedServiceType: 'AzureBlobFS'
    linkedServiceTypeProperties: {
      url: reference('Microsoft.Storage/storageAccounts/${storageAccountName}', '2019-04-01').primaryEndpoints.dfs
      accountKey: {
        type: 'AzureKeyVaultSecret'
        store: {
          referenceName: keyVaultName
          type: 'LinkedServiceReference'
        }
        secretName: storageAccountName
      }
    }
  }
}

module dataset_msexports 'datasets/adlsv2.bicep' = {
  name: 'dataset_msexports'
  dependsOn: [
    linkedService_storageAccount
    linkedService_keyVault
  ]
  params: {
    dataFactoryName: dataFactoryName
    linkedServiceName: storageAccountName
    compressionCodec: 'none'
    datasetType: 'DelimitedText'
    containerName: exportContainer.name
  }
}

module dataset_ingestion_csv 'datasets/adlsv2.bicep' = {
  name: 'dataset_ingestion_csv'
  dependsOn: [
    linkedService_storageAccount
    linkedService_keyVault
  ]
  params: {
    dataFactoryName: dataFactoryName
    linkedServiceName: storageAccountName
    datasetType: 'DelimitedText'
    containerName: ingestionContainer.name
  }
}

module dataset_ingestion_parquet 'datasets/adlsv2.bicep' = {
  name: 'dataset_ingestion_parquet'
  dependsOn: [
    linkedService_storageAccount
    linkedService_keyVault
  ]
  params: {
    dataFactoryName: dataFactoryName
    linkedServiceName: storageAccountName
    datasetType: 'Parquet'
    containerName: ingestionContainer.name
  }
}

module pipeline_msexports_extract_parquet 'pipelines/msexports_extract.bicep' = {
  name: 'pipeline_msexports_extract_parquet'
  dependsOn: [
    pipeline_msexports_transform_parquet
  ]
  params: {
    dataFactoryName: dataFactoryName
    exportContainerName: exportContainer.name
    outputFormat: 'parquet'
  }
}

module pipeline_msexports_extract_csv 'pipelines/msexports_extract.bicep' = {
  name: 'pipeline_msexports_extract_csv'
  dependsOn: [
    pipeline_msexports_transform_csv
  ]
  params: {
    dataFactoryName: dataFactoryName
    exportContainerName: exportContainer.name
    outputFormat: 'csv'
  }
}

module pipeline_msexports_transform_parquet 'pipelines/msexports_transform.bicep' = {
  name: 'pipeline_msexports_transform_parquet'
  dependsOn: [
    dataset_msexports
    dataset_ingestion_parquet
  ]
  params: {
    dataFactoryName: dataFactoryName
    sinkDataset:  replace('${ingestionContainer.name}_Parquet', '-', '_')
    sourceDataset:  replace('${exportContainer.name}_DelimitedText', '-', '_')
    ingestionContainerName: ingestionContainer.name
    exportContainerName: exportContainer.name
    outputFormat: 'parquet'
  }
}

module pipeline_msexports_transform_csv 'pipelines/msexports_transform.bicep' = {
  name: 'pipeline_msexports_transform_csv'
  dependsOn: [
    dataset_msexports
    dataset_ingestion_csv
  ]
  params: {
    dataFactoryName: dataFactoryName
    sinkDataset:  replace('${ingestionContainer.name}_DelimitedText', '-', '_')
    sourceDataset:  replace('${exportContainer.name}_DelimitedText', '-', '_')
    ingestionContainerName: ingestionContainer.name
    exportContainerName: exportContainer.name
    outputFormat: 'csv'
  }
}

module trigger_msexports 'triggers/adlsv2.bicep' = {
  name: 'trigger_msexports'
  dependsOn: [
    pipeline_msexports_extract_parquet
    pipeline_msexports_extract_csv
  ]
  params: {
    dataFactoryName: dataFactoryName
    storageAccountId: storageAccount.id
    blobContainerName: exportContainer.name
    pipelineName: '${exportContainer.name}_extract_parquet'
    triggerName: exportContainer.name
    triggerDesc: 'Monitors the ${exportContainer.name} container for new exports and executes the ${exportContainer.name}_extract_parquet pipeline.'
    autoStart: true
    autoStartLocation: dataFactory.outputs.location
  }
}

//------------------------------------------------------------------------------
// Outputs
//------------------------------------------------------------------------------

@description('Name of the deployed hub instance.')
output name string = hubName

@description('Azure resource location resources were deployed to.')
output location string = location

@description('Name of the Data Factory.')
output dataFactorytName string = dataFactoryName

@description('Resource ID of the storage account created for the hub instance. This must be used when creating the Cost Management export.')
output storageAccountId string = storageAccount.id

@description('Name of the storage account created for the hub instance. This must be used when connecting FinOps toolkit Power BI reports to your data.')
output storageAccountName string = storageAccountName

@description('URL to use when connecting custom Power BI reports to your data.')
output storageUrlForPowerBI string = 'https://${storageAccountName}.dfs.${environment().suffixes.storage}/${ingestionContainer.name}'
