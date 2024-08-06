// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

//==============================================================================
// Parameters
//==============================================================================

targetScope = 'resourceGroup'

@description('Optional. Name of the hub. Used to ensure unique resource names. Default: "finops-hub".')
param hubName string

@description('Optional. Azure location where all resources should be created. See https://aka.ms/azureregions. Default: Same as deployment.')
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
param exportScopes array = []

@description('Optional. To use Private Endpoints in an existing virtual network, add target subnet resource Id.')
param subnetResourceId string = ''

@description('Optional. To use Private Endpoints  in an existing virtual network, add target subnet resource Id for the deployment scripts')
param scriptsSubnetResourceId string = ''

@description('Optional. To create networking resources.')
@allowed([
  'Public'
  'Private'
  'PrivateWithExistingNetwork'
])
param networkingOption string = 'Public'

@description('Optional. Name of the FinOpsHub virtual network.')
param networkName string = 'vnet-finops-hub'

@description('Optional. Address prefix for the FinOpsHub virtual network.')
param networkAddressPrefix string = '10.0.0.0/24'

@description('Optional. Name of the FinOpsHub subnet.')
param networkSubnetName string = 'subnet-finops-hub'

@description('Optional. Address prefix for the FinOpsHub subnet.')
param networkSubnetPrefix string = cidrSubnet(networkAddressPrefix,25,0)

@description('Optional. Name of the FinOpsHub scripts subnet.')
param scriptsSubnetName string = 'subnet-finops-hub-scripts'

@description('Optional. Address prefix for the scripts subnet.')
param scriptsSubnetPrefix string = cidrSubnet(networkAddressPrefix,25,1)



//==============================================================================
// Resources
//==============================================================================

module hub 'modules/hub.bicep' = {
  name: 'hub'
  params: {
    hubName: hubName
    location: location
    storageSku: storageSku
    tags: tags
    tagsByResource: tagsByResource
    exportScopes: exportScopes
    subnetResourceId: (networkingOption == 'PrivateWithExistingNetwork') ? subnetResourceId : ''
    scriptsSubnetResourceId: (networkingOption == 'PrivateWithExistingNetwork') ? scriptsSubnetResourceId : ''
    networkingOption: networkingOption
    networkAddressPrefix: networkAddressPrefix
    networkName: networkName
    networkSubnetName: networkSubnetName
    scriptsSubnetName: scriptsSubnetName
    networkSubnetPrefix: networkSubnetPrefix
    scriptsSubnetPrefix: scriptsSubnetPrefix
  }
}

//==============================================================================
// Outputs
//==============================================================================

@description('The name of the resource group.')
output name string = hubName

@description('The location the resources wer deployed to.')
output location string = location

@description('Name of the Data Factory.')
output dataFactorytName string = hub.outputs.dataFactorytName

@description('The resource ID of the deployed storage account.')
output storageAccountId string = hub.outputs.storageAccountId

@description('Name of the storage account created for the hub instance. This must be used when connecting FinOps toolkit Power BI reports to your data.')
output storageAccountName string = hub.outputs.storageAccountName

@description('URL to use when connecting custom Power BI reports to your data.')
output storageUrlForPowerBI string = hub.outputs.storageUrlForPowerBI
