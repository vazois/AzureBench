<#
.SYNOPSIS
    Deploys network infrastructure (NSG, VNet, Proximity Group) and generates vmss-parameters.json.

.DESCRIPTION
    Step 1: Deploys network/network.bicep to create the shared network resources.
    Step 2: Reads deployment outputs and generates vmss-parameters.json for subsequent VMSS deployments.

.PARAMETER ResourceGroup
    Azure resource group name.

.PARAMETER Action
    deploy  - Deploy network resources and generate vmss-parameters.json (default)
    generate - Only regenerate vmss-parameters.json from existing deployment outputs

.EXAMPLE
    .\deploy-network.ps1 -ResourceGroup vazois-garnet
    .\deploy-network.ps1 -ResourceGroup vazois-garnet -Action generate
#>

param(
    [string]$ResourceGroup = 'vazois-garnet',

    [ValidateSet('deploy', 'generate')]
    [string]$Action = 'deploy',

    [string]$DeploymentName = 'network-deploy'
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$networkDir = Join-Path $scriptDir 'network'
$vmssParamsFile = Join-Path $scriptDir 'vmss-parameters.json'

if ($Action -eq 'deploy') {
    Write-Host "`n=== Deploying network resources ===" -ForegroundColor Cyan
    Write-Host "  Resource Group : $ResourceGroup"
    Write-Host "  Template       : network/network.bicep"
    Write-Host "  Parameters     : network/network-parameters.json"
    Write-Host ""

    az deployment group create `
        --resource-group $ResourceGroup `
        --name $DeploymentName `
        --template-file (Join-Path $networkDir 'network.bicep') `
        --parameters (Join-Path $networkDir 'network-parameters.json') `
        --output none

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Network deployment failed."
        exit 1
    }

    Write-Host "Network deployment succeeded." -ForegroundColor Green
}

# Read deployment outputs
Write-Host "`n=== Reading deployment outputs ===" -ForegroundColor Cyan

$outputs = az deployment group show `
    --resource-group $ResourceGroup `
    --name $DeploymentName `
    --query 'properties.outputs' `
    --output json | ConvertFrom-Json

if (-not $outputs) {
    Write-Error "Could not read deployment outputs. Ensure deployment '$DeploymentName' exists in resource group '$ResourceGroup'."
    exit 1
}

$nsgId = $outputs.nsgId.value
$vnetName = $outputs.vnetName.value
$subnetName = $outputs.subnetName.value
$accSubnetName = $outputs.accSubnetName.value
$proximityId = $outputs.proximityId.value
$location = ($outputs.PSObject.Properties | Where-Object { $_.Name -eq 'location' })?.Value
if (-not $location) {
    # Fallback: extract location from the resource ID
    $location = (az group show --name $ResourceGroup --query location -o tsv)
}

Write-Host "  nsgId        : $nsgId"
Write-Host "  vnetName     : $vnetName"
Write-Host "  subnetName   : $subnetName"
Write-Host "  accSubnetName: $accSubnetName"
Write-Host "  proximityId  : $proximityId"
Write-Host "  location     : $location"

# Generate vmss-parameters.json
$vmssParams = @{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = @{
        location      = @{ value = $location }
        subnetName    = @{ value = $subnetName }
        accSubnetName = @{ value = $accSubnetName }
        nsgId         = @{ value = $nsgId }
        proximityId   = @{ value = $proximityId }
        vnetName      = @{ value = $vnetName }
    }
}

$vmssParams | ConvertTo-Json -Depth 4 | Set-Content -Path $vmssParamsFile -Encoding utf8

Write-Host "`n=== Generated $vmssParamsFile ===" -ForegroundColor Green
Get-Content $vmssParamsFile
Write-Host ""
