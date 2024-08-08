using './main.bicep'

param hubName = 'hub8702'

//###### Parameters options
//###### Option 1: 'Public'
//Just provide the hubName

//###### Parameters options
//###### Option 2: 'Public'
//######param networkingOption = 'Private'
//Just provide the hubName

//###### Parameters options
//###### Option 2: 'PrivateWithExistingNetwork'
//######param networkingOption = 'PrivateWithExistingNetwork'
//Provide:

//param networkingOption = 'PrivateWithExistingNetwork'
//param scriptsSubnetResourceId = '/subscriptions/e3b447fd-b561-4fa4-a821-4f90799ba35d/resourceGroups/finops-hub201/providers/Microsoft.Network/virtualNetworks/vnet001/subnets/scripts'
//param subnetResourceId = '/subscriptions/e3b447fd-b561-4fa4-a821-4f90799ba35d/resourceGroups/finops-hub201/providers/Microsoft.Network/virtualNetworks/vnet001/subnets/default'
//param privateDNSZonesResourceGroupName = 'finops-hub201'

