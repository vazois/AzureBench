<#
.SYNOPSIS
    Manages SSH public keys for VMSS deployment.

.DESCRIPTION
    Reads security/manifest.conf, copies public keys, and updates vmss-parameters.json
    or pushes keys to running VMSS instances.

.PARAMETER Action
    deploy (default) - Copies .pub files from manifest BasePath to security/, updates vmss-parameters.json
    update           - SSHs into running VMSS nodes and appends new keys to authorized_keys

.PARAMETER ResourceGroup
    Azure resource group (required for 'update' action).

.PARAMETER VmssName
    VMSS name (required for 'update' action).

.PARAMETER SshUser
    SSH username on the VMSS nodes.

.EXAMPLE
    .\deploy-keys.ps1
    .\deploy-keys.ps1 -Action update -VmssName myVmss
#>

param(
    [ValidateSet('deploy', 'update')]
    [string]$Action = 'deploy',

    [string]$ResourceGroup = 'vazois-garnet',

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

if (-not $manifest.basePath -or $manifest.keys.Count -eq 0) {
    Write-Error "Invalid manifest.json: basePath or keys missing."
    exit 1
}

# Expand environment variables in basePath (e.g., %USERPROFILE%)
$basePath = [Environment]::ExpandEnvironmentVariables($manifest.basePath)

Write-Host "`n=== SSH Key Manifest ===" -ForegroundColor Cyan
Write-Host "  BasePath: $basePath"
Write-Host "  Keys    : $($manifest.keys -join ', ')"
Write-Host ""

switch ($Action) {
    'deploy' {
        # Copy .pub files from BasePath to security/
        Write-Host "=== Copying public keys ===" -ForegroundColor Cyan
        foreach ($key in $manifest.keys) {
            $src = Join-Path $basePath "$key.pub"
            $dst = Join-Path $securityDir "$key.pub"
            if (-not (Test-Path $src)) {
                Write-Warning "Key not found: $src (skipping)"
                continue
            }
            Copy-Item $src $dst -Force
            Write-Host "  Copied: $key.pub"
        }

        # Also include the vmss inter-node key
        $vmssKeyPath = Join-Path $securityDir 'id_ed25519_vmss.pub'

        # Collect all public key contents
        $pubKeys = @()
        foreach ($key in $manifest.keys) {
            $keyFile = Join-Path $securityDir "$key.pub"
            if (Test-Path $keyFile) {
                $pubKeys += (Get-Content $keyFile -Raw).Trim()
            }
        }
        if (Test-Path $vmssKeyPath) {
            $pubKeys += (Get-Content $vmssKeyPath -Raw).Trim()
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

        Write-Host "`n=== Updated $vmssParamsFile ===" -ForegroundColor Green
        Write-Host "  Keys deployed: $($pubKeys.Count) ($(($manifest.keys + @('id_ed25519_vmss')) -join ', '))"
    }

    'update' {
        if (-not $VmssName) {
            Write-Error "-VmssName is required for 'update' action."
            exit 1
        }

        Write-Host "=== Pushing keys to VMSS: $VmssName ===" -ForegroundColor Cyan

        # Collect public key contents from security/
        $pubKeys = @()
        foreach ($key in $manifest.keys) {
            $keyFile = Join-Path $securityDir "$key.pub"
            if (Test-Path $keyFile) {
                $pubKeys += (Get-Content $keyFile -Raw).Trim()
            } else {
                Write-Warning "Key file not found: $keyFile (run deploy-keys.ps1 first)"
            }
        }
        $vmssKeyPath = Join-Path $securityDir 'id_ed25519_vmss.pub'
        if (Test-Path $vmssKeyPath) {
            $pubKeys += (Get-Content $vmssKeyPath -Raw).Trim()
        }

        if ($pubKeys.Count -eq 0) {
            Write-Error "No keys found. Run '.\deploy-keys.ps1' first to copy keys."
            exit 1
        }

        # Build authorized_keys content
        $authorizedKeys = $pubKeys -join "`n"

        # Get VMSS instance IDs
        $instances = az vmss list-instances `
            --resource-group $ResourceGroup `
            --name $VmssName `
            --query '[].instanceId' -o tsv

        if (-not $instances) {
            Write-Error "No VMSS instances found for $VmssName in $ResourceGroup."
            exit 1
        }

        $instanceList = $instances -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        Write-Host "  Found $($instanceList.Count) instance(s)"

        # Push keys via run-command
        $script = "echo '$authorizedKeys' > /home/$SshUser/.ssh/authorized_keys && chmod 600 /home/$SshUser/.ssh/authorized_keys && chown $SshUser`:$SshUser /home/$SshUser/.ssh/authorized_keys"

        foreach ($instanceId in $instanceList) {
            Write-Host "  Updating instance $instanceId..." -NoNewline
            az vmss run-command invoke `
                --resource-group $ResourceGroup `
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
