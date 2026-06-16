<#
.SYNOPSIS
    Manages SSH keys for VMSS deployment and Key Vault provisioning.

.DESCRIPTION
    Reads security/manifest.json for key definitions. Supports copying public keys,
    deploying Key Vault with the VMSS inter-node private key, and pushing keys to live VMSS instances.

.PARAMETER Action
    deploy (default) - Copies .pub files to security/, updates vmss-parameters.json, deploys Key Vault + uploads VMSS private key
    vault            - Only deploys Key Vault and uploads VMSS private key
    sync             - Discovers existing Key Vault in the resource group and updates vmss-parameters.json + manifest.json
    update           - Pushes keys to running VMSS nodes via az vmss run-command

.PARAMETER rg
    Azure resource group name.

.PARAMETER VmssName
    VMSS name (required for 'update' action).

.PARAMETER SshUser
    SSH username on the VMSS nodes.

.EXAMPLE
    # Full deploy: copy keys, update params, deploy Key Vault, upload VMSS private key
    .\deploy-keys.ps1

    # Only deploy Key Vault and upload VMSS private key
    .\deploy-keys.ps1 -Action vault

    # Discover existing Key Vault in RG and update vmss-parameters.json
    .\deploy-keys.ps1 -Action sync -rg garnet-bench

    # Push keys to running VMSS instances
    .\deploy-keys.ps1 -Action update -VmssName myVmss

    # Use a different resource group
    .\deploy-keys.ps1 -rg my-resource-group
#>

param(
    [ValidateSet('deploy', 'vault', 'sync', 'update')]
    [string]$Action = 'deploy',

    [Alias('ResourceGroup')]
    [string]$rg = 'vazois-garnet',

    [string]$VmssName,

    [string]$SshUser = 'guser'
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$securityDir = Join-Path $scriptDir 'security'
$manifestFile = Join-Path $securityDir 'manifest.json'
$vmssParamsFile = Join-Path $scriptDir 'vmss-parameters.json'

# Parse manifest.json
$manifest = Get-Content $manifestFile -Raw | ConvertFrom-Json

if (-not $manifest.basePath -or -not $manifest.userKeys -or -not $manifest.vmKeys) {
    Write-Error "Invalid manifest.json: basePath, userKeys, or vmKeys missing."
    exit 1
}

# Expand environment variables in basePath (e.g., %USERPROFILE%)
$basePath = [Environment]::ExpandEnvironmentVariables($manifest.basePath)

# Auto-generate Key Vault name: kv-{yyyyMMddHHmmss} (max 24 chars)
$kvName = "kv-$(Get-Date -Format 'yyyyMMddHHmmss')"

Write-Host "`n=== SSH Key Manifest ===" -ForegroundColor Cyan
Write-Host "  BasePath     : $basePath"
Write-Host "  User Keys    : $($manifest.userKeys -join ', ')"
Write-Host "  VM Keys      : $($manifest.vmKeys)"
Write-Host "  Key Vault    : $kvName"
Write-Host ""

# --- Shared function: Deploy Key Vault and upload VMSS private key ---
function Deploy-Vault {
    Write-Host "=== Deploying Key Vault ===" -ForegroundColor Cyan

    if (-not $kvName) {
        Write-Error "keyVaultName could not be determined."
        exit 1
    }

    # Check if Key Vault already exists
    $kvExists = az keyvault show --name $kvName --resource-group $rg --query name -o tsv 2>$null
    if ($kvExists) {
        Write-Host "  Key Vault '$kvName' already exists."
    } else {
        # Check for soft-deleted vault with the same name
        $softDeleted = az keyvault show-deleted --name $kvName --query name -o tsv 2>$null
        if ($softDeleted) {
            Write-Host "  Found soft-deleted vault '$kvName'. Purging..." -ForegroundColor Yellow
            az keyvault purge --name $kvName --output none 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Could not purge '$kvName'. Generating a new unique name."
                $kvName = "kv-$(Get-Date -Format 'yyyyMMddHHmmss')"
                Write-Host "  Using: $kvName"
            } else {
                Write-Host "  Purged. Proceeding with creation."
            }
        }

        Write-Host "  Creating Key Vault '$kvName'..."
        $kvBicep = Join-Path $securityDir 'keyvault.bicep'
        if (-not (Test-Path $kvBicep)) {
            Write-Error "keyvault.bicep not found in $securityDir"
            exit 1
        }

        $location = (az group show --name $rg --query location -o tsv)
        $deployerOid = (az ad signed-in-user show --query id -o tsv)
        az deployment group create `
            --resource-group $rg `
            --template-file $kvBicep `
            --parameters keyVaultName=$kvName location=$location deployerPrincipalId=$deployerOid `
            --output none

        if ($LASTEXITCODE -ne 0) {
            Write-Error "Key Vault deployment failed."
            exit 1
        }
        Write-Host "  Key Vault '$kvName' created." -ForegroundColor Green
        Write-Host "  Waiting for RBAC propagation..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 15
    }

    # Save vault name back to manifest.json for future runs
    $manifest | Add-Member -NotePropertyName 'keyVaultName' -NotePropertyValue $kvName -Force
    $manifest | ConvertTo-Json -Depth 3 | Set-Content -Path $manifestFile -Encoding utf8
    Write-Host "  Saved keyVaultName='$kvName' to manifest.json"

    # Upload VMSS private key as secret
    $vmKeyName = $manifest.vmKeys
    $privateKeyPath = Join-Path $basePath $vmKeyName
    if (-not (Test-Path $privateKeyPath)) {
        Write-Error "VMSS private key not found: $privateKeyPath"
        exit 1
    }

    Write-Host "  Uploading '$vmKeyName' private key to Key Vault..."
    $secretName = 'vmss-ssh-private'
    az keyvault secret set `
        --vault-name $kvName `
        --name $secretName `
        --file $privateKeyPath `
        --output none 2>$null

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to upload secret '$secretName' to Key Vault."
        exit 1
    }

    Write-Host "  Secret '$secretName' uploaded." -ForegroundColor Green

    # Update vmss-parameters.json with keyVaultName
    if (Test-Path $vmssParamsFile) {
        $params = Get-Content $vmssParamsFile -Raw | ConvertFrom-Json
        $params.parameters | Add-Member -NotePropertyName 'keyVaultName' -NotePropertyValue @{ value = $kvName } -Force
        $params | ConvertTo-Json -Depth 5 | Set-Content -Path $vmssParamsFile -Encoding utf8
        Write-Host "  Updated $vmssParamsFile with keyVaultName=$kvName" -ForegroundColor Green
    }
}

switch ($Action) {
    'deploy' {
        # Copy .pub files from BasePath to security/
        Write-Host "=== Copying public keys ===" -ForegroundColor Cyan
        foreach ($key in $manifest.userKeys) {
            $src = Join-Path $basePath "$key.pub"
            $dst = Join-Path $securityDir "$key.pub"
            if (-not (Test-Path $src)) {
                Write-Warning "Key not found: $src (skipping)"
                continue
            }
            Copy-Item $src $dst -Force
            Write-Host "  Copied: $key.pub"
        }

        # Copy vmKeys .pub file
        $vmKeyPubSrc = Join-Path $basePath "$($manifest.vmKeys).pub"
        $vmKeyPubDst = Join-Path $securityDir "$($manifest.vmKeys).pub"
        if (Test-Path $vmKeyPubSrc) {
            Copy-Item $vmKeyPubSrc $vmKeyPubDst -Force
            Write-Host "  Copied: $($manifest.vmKeys).pub"
        }

        # Collect all public key contents
        $pubKeys = @()
        foreach ($key in $manifest.userKeys) {
            $keyFile = Join-Path $securityDir "$key.pub"
            if (Test-Path $keyFile) {
                $pubKeys += (Get-Content $keyFile -Raw).Trim()
            }
        }
        if (Test-Path $vmKeyPubDst) {
            $pubKeys += (Get-Content $vmKeyPubDst -Raw).Trim()
        }

        # Update vmss-parameters.json
        if (Test-Path $vmssParamsFile) {
            $params = Get-Content $vmssParamsFile -Raw | ConvertFrom-Json
        } else {
            $params = @{
                '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
                contentVersion = '1.0.0.0'
                parameters = @{}
            }
        }

        # Add/update sshPublicKeys parameter
        $params.parameters | Add-Member -NotePropertyName 'sshPublicKeys' -NotePropertyValue @{ value = $pubKeys } -Force
        $params | ConvertTo-Json -Depth 5 | Set-Content -Path $vmssParamsFile -Encoding utf8

        $allKeyNames = @($manifest.userKeys) + @($manifest.vmKeys)
        Write-Host "`n=== Updated $vmssParamsFile ===" -ForegroundColor Green
        Write-Host "  Keys deployed: $($pubKeys.Count) ($($allKeyNames -join ', '))"

        # Deploy Key Vault and upload VMSS private key
        Write-Host ""
        Deploy-Vault
    }

    'vault' {
        Deploy-Vault
    }

    'sync' {
        Write-Host "=== Discovering Key Vault in '$rg' ===" -ForegroundColor Cyan
        $vaults = az keyvault list --resource-group $rg --query "[].name" -o tsv 2>$null
        if (-not $vaults) {
            Write-Error "No Key Vault found in resource group '$rg'."
            exit 1
        }

        $vaultList = $vaults -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        if ($vaultList.Count -gt 1) {
            Write-Host "  Multiple vaults found:" -ForegroundColor Yellow
            $vaultList | ForEach-Object { Write-Host "    - $_" }
            Write-Host "  Using first: $($vaultList[0])" -ForegroundColor Yellow
        }

        $discoveredKv = $vaultList[0]
        Write-Host "  Key Vault: $discoveredKv"

        # Update manifest.json
        $manifest | Add-Member -NotePropertyName 'keyVaultName' -NotePropertyValue $discoveredKv -Force
        $manifest | ConvertTo-Json -Depth 3 | Set-Content -Path $manifestFile -Encoding utf8
        Write-Host "  Updated manifest.json with keyVaultName=$discoveredKv" -ForegroundColor Green

        # Update vmss-parameters.json
        if (Test-Path $vmssParamsFile) {
            $params = Get-Content $vmssParamsFile -Raw | ConvertFrom-Json
        } else {
            $params = @{
                '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
                contentVersion = '1.0.0.0'
                parameters = @{}
            }
        }
        $params.parameters | Add-Member -NotePropertyName 'keyVaultName' -NotePropertyValue @{ value = $discoveredKv } -Force
        $params | ConvertTo-Json -Depth 5 | Set-Content -Path $vmssParamsFile -Encoding utf8
        Write-Host "  Updated $vmssParamsFile with keyVaultName=$discoveredKv" -ForegroundColor Green
    }

    'update' {
        if (-not $VmssName) {
            Write-Error "-VmssName is required for 'update' action."
            exit 1
        }

        Write-Host "=== Pushing keys to VMSS: $VmssName ===" -ForegroundColor Cyan

        # Collect public key contents from security/
        $pubKeys = @()
        foreach ($key in $manifest.userKeys) {
            $keyFile = Join-Path $securityDir "$key.pub"
            if (Test-Path $keyFile) {
                $pubKeys += (Get-Content $keyFile -Raw).Trim()
            } else {
                Write-Warning "Key file not found: $keyFile (run deploy-keys.ps1 first)"
            }
        }
        $vmKeyPubPath = Join-Path $securityDir "$($manifest.vmKeys).pub"
        if (Test-Path $vmKeyPubPath) {
            $pubKeys += (Get-Content $vmKeyPubPath -Raw).Trim()
        }

        if ($pubKeys.Count -eq 0) {
            Write-Error "No keys found. Run '.\deploy-keys.ps1' first to copy keys."
            exit 1
        }

        # Build authorized_keys content
        $authorizedKeys = $pubKeys -join "`n"

        # Get VMSS instance IDs
        $instances = az vmss list-instances `
            --resource-group $rg `
            --name $VmssName `
            --query '[].instanceId' -o tsv

        if (-not $instances) {
            Write-Error "No VMSS instances found for $VmssName in $rg."
            exit 1
        }

        $instanceList = $instances -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        Write-Host "  Found $($instanceList.Count) instance(s)"

        # Push keys via run-command
        $script = "echo '$authorizedKeys' > /home/$SshUser/.ssh/authorized_keys && chmod 600 /home/$SshUser/.ssh/authorized_keys && chown $SshUser`:$SshUser /home/$SshUser/.ssh/authorized_keys"

        foreach ($instanceId in $instanceList) {
            Write-Host "  Updating instance $instanceId..." -NoNewline
            az vmss run-command invoke `
                --resource-group $rg `
                --name $VmssName `
                --instance-id $instanceId `
                --command-id RunShellScript `
                --scripts $script `
                --output none 2>$null

            if ($LASTEXITCODE -eq 0) {
                Write-Host " OK" -ForegroundColor Green
            } else {
                Write-Host " FAILED" -ForegroundColor Red
            }
        }

        Write-Host "`n=== Key update complete ===" -ForegroundColor Green
    }
}
