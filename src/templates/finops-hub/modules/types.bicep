//==============================================================================
// User-defined types
//==============================================================================

@export()
@discriminator('networkingOption')
type networkingOptionType = existingNetworkingType | newNetworkingType

@export()
type existingNetworkingType = {
  @description('Use an existing virtual network configured for private endpoint.')
  networkingOption: 'existing'

  @description('The subnet resource Id where private endpoints are going to be deployed.')
  subnetResourceId: string

  @description('The subnet resource Id where deployment scripts are going to be deployed.')
  scriptsSubnetResourceId: string
}

@export()
type newNetworkingType = {
  @description('Create a new virtual network, subnet and private DNS zones for private endpoints.')
  networkingOption: 'createNew'

  @description('Name of the virtual network to create.')
  vnetName: string

  @description('Name of the subnet to create for private endpoints.')
  subnetName: string

  @description('Name of the subnet to create for deployment scripts.')
  scriptsSubnetName: string

  @description('Address prefix for the virtual network.')
  addressPrefix: string
}
