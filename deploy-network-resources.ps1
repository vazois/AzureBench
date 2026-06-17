<#
.SYNOPSIS
    Deploys network infrastructure (NSG, VNet, Proximity Group) and generates vmss-parameters.json.

.DESCRIPTION
    Step 1: Deploys network/network.bicep to create the shared network resources.
    Step 2: Reads deployment outputs and generates vmss-parameters.json for subsequent VMSS deployments.

.PARAMETER rg
    Azure resource group name.

.PARAMETER Action
    deploy - Deploy network resources and generate vmss-parameters.json (default)
    stage  - Query existing resources in the resource group and generate vmss-parameters.json (no deployment)

.EXAMPLE
    # Deploy network resources using default resource group (vazois-garnet)
    .\deploy-network-resources.ps1

    # Deploy network resources to a specific resource group
    .\deploy-network-resources.ps1 -rg my-resource-group

    # Generate vmss-parameters.json from existing resources (no deployment)
    .\deploy-network-resources.ps1 -Action stage -rg my-resource-group

    # Deploy to a specific resource group with a custom deployment name
    .\deploy-network-resources.ps1 -rg my-resource-group -Action deploy -DeploymentName my-deploy
#>

param(
    [Alias('ResourceGroup')]
    [string]$rg = 'vazois-garnet',

    [ValidateSet('deploy', 'stage')]
    [string]$Action = 'deploy',

    [string]$DeploymentName = 'network-deploy'
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$networkDir = Join-Path $scriptDir 'network'
$vmssParamsFile = Join-Path $scriptDir 'vmss-parameters.json'

function Write-VmssParams {
    param(
        [string]$Location, [string]$NsgId, [string]$VnetName,
        [string]$SubnetName, [string]$AccSubnetName, [string]$ProximityId
    )

    Write-Host "  nsgId         : $NsgId"
    Write-Host "  vnetName      : $VnetName"
    Write-Host "  subnetName    : $SubnetName"
    Write-Host "  accSubnetName : $AccSubnetName"
    Write-Host "  proximityId   : $ProximityId"
    Write-Host "  location      : $Location"

    $vmssParams = @{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = @{
            location      = @{ value = $Location }
            subnetName    = @{ value = $SubnetName }
            accSubnetName = @{ value = $AccSubnetName }
            nsgId         = @{ value = $NsgId }
            proximityId   = @{ value = $ProximityId }
            vnetName      = @{ value = $VnetName }
        }
    }

    $vmssParams | ConvertTo-Json -Depth 4 | Set-Content -Path $vmssParamsFile -Encoding utf8

    Write-Host "`n=== Generated $vmssParamsFile ===" -ForegroundColor Green
    Get-Content $vmssParamsFile
    Write-Host ""
}

# Check if resource group exists
$rgExists = az group exists --name $rg 2>$null
if ($rgExists -ne 'true') {
    if ($Action -eq 'stage') {
        Write-Error "Resource group '$rg' does not exist."
        exit 1
    }
    Write-Host "Resource group '$rg' does not exist." -ForegroundColor Yellow
    $create = Read-Host "Would you like to create it? (y/N)"
    if ($create -eq 'y' -or $create -eq 'Y') {
        $location = Read-Host "Location (default: southcentralus)"
        if (-not $location) { $location = 'southcentralus' }
        az group create --name $rg --location $location --output none
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to create resource group '$rg'."
            exit 1
        }
        Write-Host "Resource group '$rg' created in '$location'." -ForegroundColor Green
    } else {
        Write-Error "Resource group '$rg' does not exist. Aborting."
        exit 1
    }
}

if ($Action -eq 'stage') {
    Write-Host "`n=== Querying resources in '$rg' ===" -ForegroundColor Cyan

    $location = az group show --name $rg --query location -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $location) {
        Write-Error "Could not determine resource group location."
        exit 1
    }

    $nsgId = az network nsg list --resource-group $rg --query '[0].id' -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $nsgId) {
        Write-Error "No NSG found in resource group '$rg'."
        exit 1
    }

    $vnetJson = az network vnet list --resource-group $rg --query '[0].{name:name, subnets:subnets[].name}' -o json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $vnetJson) {
        Write-Error "No VNet found in resource group '$rg'."
        exit 1
    }
    $vnetName = $vnetJson.name
    $subnets = $vnetJson.subnets
    if ($subnets.Count -lt 2) {
        Write-Error "Expected at least 2 subnets in VNet '$vnetName', found $($subnets.Count)."
        exit 1
    }
    $subnetName = $subnets[0]
    $accSubnetName = $subnets[1]

    $proximityId = az ppg list --resource-group $rg --query '[0].id' -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $proximityId) {
        Write-Error "No proximity placement group found in resource group '$rg'."
        exit 1
    }

    Write-VmssParams -Location $location -NsgId $nsgId -VnetName $vnetName `
        -SubnetName $subnetName -AccSubnetName $accSubnetName -ProximityId $proximityId
    exit 0
}

# Action = deploy
Write-Host "`n=== Deploying network resources ===" -ForegroundColor Cyan
Write-Host "  Resource Group : $rg"
Write-Host "  Template       : network/network.bicep"
Write-Host "  Parameters     : network/network-parameters.json"
Write-Host ""

az deployment group create `
    --resource-group $rg `
    --name $DeploymentName `
    --template-file (Join-Path $networkDir 'network.bicep') `
    --parameters (Join-Path $networkDir 'network-parameters.json') `
    --output none

if ($LASTEXITCODE -ne 0) {
    Write-Error "Network deployment failed."
    exit 1
}

Write-Host "Network deployment succeeded." -ForegroundColor Green

# Read deployment outputs
Write-Host "`n=== Reading deployment outputs ===" -ForegroundColor Cyan

$outputs = az deployment group show `
    --resource-group $rg `
    --name $DeploymentName `
    --query 'properties.outputs' `
    --output json | ConvertFrom-Json

if (-not $outputs) {
    Write-Error "Could not read deployment outputs. Ensure deployment '$DeploymentName' exists in resource group '$rg'."
    exit 1
}

$nsgId = $outputs.nsgId.value
$vnetName = $outputs.vnetName.value
$subnetName = $outputs.subnetName.value
$accSubnetName = $outputs.accSubnetName.value
$proximityId = $outputs.proximityId.value
$location = ($outputs.PSObject.Properties | Where-Object { $_.Name -eq 'location' })?.Value
if (-not $location) {
    $location = (az group show --name $rg --query location -o tsv)
}

Write-VmssParams -Location $location -NsgId $nsgId -VnetName $vnetName `
    -SubnetName $subnetName -AccSubnetName $accSubnetName -ProximityId $proximityId
