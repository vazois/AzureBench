/* VMSS-PARAMETERS.JSON inputs */
param location string
param nsgId string
param subnetName string
param accSubnetName string
// param clientSubnetName string  // Uncomment to enable separate client subnet (10.5.2.X)
param proximityId string
param vnetName string

param vmssName string
param instanceCount int

// NOTE: vmssRole and clientSubnetName support separate subnets for server (10.5.1.X) and client (10.5.2.X).
// Currently disabled — cluster-deploy.ps1 filters peers by VMSS hostname prefix, so both can share accSubnet.
// Uncomment and remove the hardcoded dataSubnetName below to re-enable subnet separation.
// @description('Role of this VMSS. Server uses accSubnet (10.5.1.X), client uses clientSubnet (10.5.2.X).')
// @allowed([
//   'server'
//   'client'
// ])
// param vmssRole string

@allowed([
  'linux'
  'windows'
])
param operatingSystem string

@allowed([
  'Premium_LRS'
  'Premium_ZRS'
  'Standard_LRS'
  'UltraSSD_LRS'
])
param osDiskType string

////////////////////
/// SKU Options ////
@description('VM family with supported core counts. Pick a family, then choose vmCores from the listed options.')
@allowed([
  // x64 SKUs
  'E_v3: [8, 20, 64]'
  'Fs_v2: [8, 32, 64, 72]'
  'DSv2: [8, 16]'
  // AMD
  'Fas_v6: [8, 32,64]'
  'Fas_v7: [8, 32,64,80]'
  // ARM v5: Ampere Altra
  'Dpls_v5: [8, 32, 64]'
  'Dps_v5: [8, 32, 64]'
  'Dpds_v5: [8, 32, 64]'
  'Eps_v5: [8, 20, 32]'
  'Epds_v5: [8, 32]'
  // ARM v6: Ampere
  'Dpls_v6: [8, 32, 48, 64, 96]'
  'Dps_v6: [8, 32, 48, 64, 96]'
  'Dpds_v6: [8, 32, 64, 96]'
  'Eps_v6: [8, 32, 48, 64, 96]'
  'Epds_v6: [8, 32, 64, 96]'
])
param vmFamily string

@description('Number of vCPUs. Enter one of the core counts shown in brackets [] next to your chosen vmFamily above.')
@metadata({
  hint: 'Valid options are listed in the vmFamily selection. Invalid choices will be rejected by Azure.'
})
param vmCores int

// Extract the actual family name by splitting on ':'
// e.g. 'Dps_v6: [32, 48, 64, 96]' → 'Dps_v6'
var familyName = split(vmFamily, ':')[0]

// DSv2 uses model numbers instead of core counts (DS5_v2 = 16 cores)
// Build the full SKU name: Standard_<series><cores><suffix>_v<gen>
// e.g. familyName "Dps_v6" + cores 64 → series "D" + suffix "ps_v6" → "Standard_D64ps_v6"
// e.g. familyName "Fs_v2" + cores 72 → series "F" + suffix "s_v2" → "Standard_F72s_v2"
var seriesLetter = substring(familyName, 0, 1)
var suffixAndVersion = substring(familyName, 1, max(0, length(familyName) - 1))
var vmSKU = familyName == 'DSv2' ? 'Standard_DS5_v2' : 'Standard_${seriesLetter}${vmCores}${suffixAndVersion}'

// ARM-based SKUs do not support Trusted Launch.
// x64 families: E_v3, Fs_v2, Fas_v6, DSv2
var x64Families = ['E_v3', 'Fs_v2', 'Fas_v6', 'DSv2']
var supportsTrustedLaunch = contains(x64Families, familyName)
var securityProfileConfig = supportsTrustedLaunch
  ? {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
  : {
      securityType: 'Standard'
    }
//////////////////

@allowed([
  'ReadOnly'
  'ReadWrite'
  'None'
])
param diskCaching string = 'ReadWrite'

param adminUsername string = 'guser'
@description('Windows computer name prefix. Used only when operatingSystem = windows.')
param computerName string = vmssName

@description('Windows admin password. Required when operatingSystem = windows.')
@secure()
param adminPassword string = ''

@description('Key Vault name for storing VMSS SSH private key and GitHub PAT. Leave empty to skip.')
param keyVaultName string = 'garnet-kv'

///////////////////////////////////////////////////////
/////////////////// OS Options ////////////////////////
@description('Linux VM image. Used only when operatingSystem = linux.')
@allowed([
  {
    publisher: 'Canonical'
    offer: 'ubuntu-24_04-lts'
    sku: 'server'
    version: 'latest'
  }
  {
    publisher: 'microsoftcblmariner'
    offer: 'azure-linux-3'
    sku: 'azure-linux-3-gen2'
    version: 'latest'
  }
  {
    publisher: 'microsoftcblmariner'
    offer: 'azure-linux-3'
    sku: 'azure-linux-3-arm64'
    version: 'latest'
  }
  {
    publisher: 'microsoftcblmariner'
    offer: 'cbl-mariner'
    sku: 'cbl-mariner-2-gen2'
    version: 'latest'
  }
  {
    publisher: 'Canonical'
    offer: '0001-com-ubuntu-server-jammy'
    sku: '22_04-lts-gen2'
    version: 'latest'
  }
  {
    publisher: 'Canonical'
    offer: '0001-com-ubuntu-server-jammy'
    sku: '22_04-lts-arm64'
    version: 'latest'
  }
])
param linuxImage object

@description('Windows VM image. Used only when operatingSystem = windows.')
param windowsImage object = {
  publisher: 'MicrosoftWindowsServer'
  offer: 'WindowsServer'
  sku: '2022-datacenter-g2'
  version: 'latest'
}

var selectedImage = operatingSystem == 'linux' ? linuxImage : windowsImage

var storageProfileConfig = {
  osDisk: operatingSystem == 'linux'
    ? {
        createOption: 'FromImage'
        caching: diskCaching
        managedDisk: {
          storageAccountType: osDiskType
        }
        diskSizeGB: 128
      }
    : {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: osDiskType
        }
        diskSizeGB: 128
      }
  imageReference: {
    publisher: selectedImage.publisher
    offer: selectedImage.offer
    sku: selectedImage.sku
    version: selectedImage.version
  }
}
///////////////////////////////////////////////////////

/////////////// LINUX CONFIG OPTIONS ///////////////////
var isAzureLinux = linuxImage.publisher == 'microsoftcblmariner'

// Load cloud-config templates and inject keyVaultName
var cloudInitAzureLinuxRaw = loadTextContent('cloud-config-azurelinux.yml')
var cloudInitUbuntuRaw = loadTextContent('cloud-config.yml')
var cloudInitAzureLinuxFinal = replace(cloudInitAzureLinuxRaw, '__KEYVAULT_NAME__', keyVaultName)
var cloudInitUbuntuFinal = replace(cloudInitUbuntuRaw, '__KEYVAULT_NAME__', keyVaultName)

var cloudInitUbuntu = base64(cloudInitUbuntuFinal)
var cloudInitAzureLinux = base64(cloudInitAzureLinuxFinal)
var cloudInitData = isAzureLinux ? cloudInitAzureLinux : cloudInitUbuntu

param sshPublicKeys array
var installSoftwareScriptBase64 = base64(loadTextContent('install-software.ps1'))
////////////////////////////////////////////////////////

////////////////////// NETWORK CONFIG OPTIONS //////////////////////////
var publicIPAddressName = '${vmssName}-PublicIP'
var dnsLabelPrefix = vmssName
var zones = ['1']
var nicName = '${vmssName}-nic'
var accNicName = '${vmssName}-acc-nic'
// var dataSubnetName = vmssRole == 'server' ? accSubnetName : clientSubnetName
var dataSubnetName = accSubnetName

var ipTagsProfile = {
  ipTagType: 'FirstPartyUsage'
  tag: '/NonProd'
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-04-01' existing = {
  name: vnetName
}

var tagsProfile = {
  Environment: '/NonProd'
  Owner: 'vazois'
  Root: vmssName
}

var networkProfileConfig = {
  networkInterfaceConfigurations: [
    {
      name: nicName
      properties: {
        primary: true
        ipConfigurations: [
          {
            name: 'ipconfig1'
            properties: {
              subnet: {
                id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, subnetName)
              }
              privateIPAddressVersion: 'IPv4'
              publicIPAddressConfiguration: {
                name: publicIPAddressName
                sku: {
                  name: 'Standard'
                }
                properties: {
                  publicIPAddressVersion: 'IPv4'
                  dnsSettings: {
                    domainNameLabel: dnsLabelPrefix
                  }
                  ipTags: [ipTagsProfile]
                }
              }
            }
          }
        ]
        networkSecurityGroup: {
          id: nsgId
        }
      }
    }
    {
      name: accNicName
      properties: {
        primary: false
        enableAcceleratedNetworking: true
        ipConfigurations: [
          {
            name: 'ipconfig2'
            properties: {
              subnet: {
                id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, dataSubnetName)
              }
            }
          }
        ]
        networkSecurityGroup: {
          id: nsgId
        }
      }
    }
  ]
}
///////////////////////////////////////////////////////////////////////

resource linuxVmss 'Microsoft.Compute/virtualMachineScaleSets@2024-03-01' = if (operatingSystem == 'linux') {
  name: vmssName
  location: location
  zones: zones
  tags: tagsProfile
  sku: {
    capacity: instanceCount
    name: vmSKU
    tier: 'Standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    overprovision: false
    singlePlacementGroup: true
    upgradePolicy: {
      mode: 'Automatic'
      automaticOSUpgradePolicy: {
        enableAutomaticOSUpgrade: true
      }
    }
    proximityPlacementGroup: {
      id: proximityId
    }
    virtualMachineProfile: {
      osProfile: {
        computerNamePrefix: vmssName
        adminUsername: adminUsername
        linuxConfiguration: {
          disablePasswordAuthentication: true
          ssh: {
            publicKeys: [for key in sshPublicKeys: {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: key
            }]
          }
        }
        customData: cloudInitData
      }
      storageProfile: storageProfileConfig
      securityProfile: securityProfileConfig
      networkProfile: networkProfileConfig
      extensionProfile: {
        extensions: [
          {
            name: 'AADSSHLoginForLinux'
            properties: {
              publisher: 'Microsoft.Azure.ActiveDirectory'
              type: 'AADSSHLoginForLinux'
              typeHandlerVersion: '1.0'
              autoUpgradeMinorVersion: true
              settings: {}
            }
          }
          {
            name: 'HealthExtension'
            properties: {
              publisher: 'Microsoft.ManagedServices'
              type: 'ApplicationHealthLinux'
              autoUpgradeMinorVersion: true
              enableAutomaticUpgrade: true
              typeHandlerVersion: '1.0'
              settings: {
                protocol: 'tcp'
                port: 22
                intervalInSeconds: 5
                numberOfProbes: 1
              }
            }
          }
        ]
        extensionsTimeBudget: 'PT90M'
      }
    }
  }
}

resource windowsVmss 'Microsoft.Compute/virtualMachineScaleSets@2024-03-01' = if (operatingSystem == 'windows') {
  name: vmssName
  location: location
  zones: zones
  tags: tagsProfile
  sku: {
    capacity: instanceCount
    name: vmSKU
    tier: 'Standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    overprovision: false
    singlePlacementGroup: true
    upgradePolicy: {
      mode: 'Automatic'
    }
    proximityPlacementGroup: {
      id: proximityId
    }
    virtualMachineProfile: {
      osProfile: {
        computerNamePrefix: substring(computerName, 0, 9)
        adminUsername: adminUsername
        adminPassword: adminPassword
        windowsConfiguration: {
          enableAutomaticUpdates: true
        }
      }
      storageProfile: storageProfileConfig
      securityProfile: securityProfileConfig
      networkProfile: networkProfileConfig
      extensionProfile: {
        extensions: [
          {
            name: 'AADLoginForWindows'
            properties: {
              publisher: 'Microsoft.Azure.ActiveDirectory'
              type: 'AADLoginForWindows'
              typeHandlerVersion: '1.0'
              autoUpgradeMinorVersion: true
            }
          }
          {
            name: 'InstallTools'
            properties: {
              publisher: 'Microsoft.Compute'
              type: 'CustomScriptExtension'
              typeHandlerVersion: '1.10'
              autoUpgradeMinorVersion: true
              protectedSettings: {
                script: installSoftwareScriptBase64
              }
            }
          }
          {
            name: 'HealthExtension'
            properties: {
              publisher: 'Microsoft.ManagedServices'
              type: 'ApplicationHealthWindows'
              autoUpgradeMinorVersion: true
              enableAutomaticUpgrade: true
              typeHandlerVersion: '1.0'
              settings: {
                protocol: 'tcp'
                port: 22
                intervalInSeconds: 5
                numberOfProbes: 1
              }
            }
          }
        ]
      }
    }
  }
}

resource linuxGuestConfigExtension 'Microsoft.Compute/virtualMachineScaleSets/extensions@2020-12-01' = if (operatingSystem == 'linux') {
  parent: linuxVmss
  name: 'AzurePolicyforLinux'
  properties: {
    publisher: 'Microsoft.GuestConfiguration'
    type: 'ConfigurationForLinux'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
    settings: {}
    protectedSettings: {}
  }
}

resource windowsGuestConfigExtension 'Microsoft.Compute/virtualMachineScaleSets/extensions@2020-12-01' = if (operatingSystem == 'windows') {
  parent: windowsVmss
  name: 'AzurePolicyforWindows'
  properties: {
    publisher: 'Microsoft.GuestConfiguration'
    type: 'ConfigurationforWindows'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
    settings: {}
    protectedSettings: {}
  }
}

// Grant VMSS managed identity access to Key Vault secrets (access policy model)
resource existingKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (!empty(keyVaultName)) {
  name: keyVaultName
}

resource kvAccessPolicy 'Microsoft.KeyVault/vaults/accessPolicies@2023-07-01' = if (!empty(keyVaultName)) {
  name: 'add'
  parent: existingKeyVault
  properties: {
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        #disable-next-line BCP318
        objectId: operatingSystem == 'linux' ? linuxVmss.identity.principalId : windowsVmss.identity.principalId
        permissions: {
          secrets: ['get']
        }
      }
    ]
  }
}

output vmssResourceId string = operatingSystem == 'linux' ? linuxVmss.id : windowsVmss.id
