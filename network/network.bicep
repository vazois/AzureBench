@allowed([
  'westus3'
  'eastus'
  'southcentralus'
  'centralus'
])
param location string

param networkSecurityGroupName string
param virtualNetworkName string
param subnetName string
param accSubnetName string
param proximityGroupName string

var addressPrefix = '10.5.0.0/16'
var subnetAddressPrefix = '10.5.0.0/24'
var accSubnetAddressPrefix = '10.5.1.0/24'

// Network Security Group — shared by both subnets
resource nsg 'Microsoft.Network/networkSecurityGroups@2020-06-01' = {
  name: networkSecurityGroupName
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowCorpnetSSH'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: 'CorpNetPublic'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 2000
          direction: 'Inbound'
          sourcePortRanges: []
          destinationPortRanges: []
          sourceAddressPrefixes: []
          destinationAddressPrefixes: []
        }
      }
      {
        name: 'AllowCorpnetRDP'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: 'CorpNetPublic'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 2010
          direction: 'Inbound'
          sourcePortRanges: []
          destinationPortRanges: []
          sourceAddressPrefixes: []
          destinationAddressPrefixes: []
        }
      }
    ]
  }
}

// Virtual Network with two subnets, both associated with the same NSG
resource vnet 'Microsoft.Network/virtualNetworks@2020-06-01' = {
  name: virtualNetworkName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetAddressPrefix
          privateEndpointNetworkPolicies: 'Enabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
          networkSecurityGroup: { id: nsg.id }
        }
      }
      {
        name: accSubnetName
        properties: {
          addressPrefix: accSubnetAddressPrefix
          privateEndpointNetworkPolicies: 'Enabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

// Proximity Placement Group
resource prg 'Microsoft.Compute/proximityPlacementGroups@2021-03-01' = {
  name: proximityGroupName
  location: location
  properties: {
    proximityPlacementGroupType: 'Standard'
  }
}

output nsgId string = nsg.id
output vnetName string = vnet.name
output subnetName string = subnetName
output accSubnetName string = accSubnetName
output proximityId string = prg.id
