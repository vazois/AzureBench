# AzureBench

Automated deployment of benchmarking environments on Azure using VMSS (Virtual Machine Scale Sets).

## Setup Steps

### 1. Prerequisites

- Azure CLI (`az`) logged in
- PowerShell 7+
- Resource group created (default: `vazois-garnet`)

### 2. Deploy Network Resources

```powershell
.\deploy-network-resources.ps1
```

Creates NSGs, VNet (with two subnets), and a proximity placement group. Auto-generates `vmss-parameters.json` with resource IDs.

### 3. Configure SSH Keys

Edit `security/manifest.json` to declare your SSH key names and base path. Then run:

```powershell
.\deploy-keys.ps1
```

This copies public keys locally and populates `vmss-parameters.json` with their contents.

### 4. Deploy VMSS

```powershell
az deployment group create `
  --resource-group vazois-garnet `
  --template-file vmss.bicep `
  --parameters @vmss-parameters.json `
  --parameters vmssName=<name> instanceCount=<n> vmSKU=<sku>
```

VMs are provisioned via cloud-init with .NET SDKs, repos, and tooling pre-installed.

### 5. Run Benchmarks

```powershell
.\benchmark\resp-bench.ps1
```

Launches benchmark workloads across VMSS nodes using SSH, aggregates results.

### 6. Update Keys on Live VMSS (Optional)

```powershell
.\deploy-keys.ps1 -Action update -VmssName <name>
```

Pushes new SSH keys to running VMs without redeployment.

## File Structure

| Path | Purpose |
|------|---------|
| `vmss.bicep` | VMSS deployment template |
| `network/` | Network infrastructure (NSG, VNet, proximity group) |
| `security/` | SSH key manifest and public keys |
| `node/` | Node-side scripts (deploy, cluster, storage-conf, benchmark) |
| `deploy-keys.ps1` | Key sync and live update |
| `deploy-network-resources.ps1` | Network deployment + param generation |
| `cloud-config-azurelinux.yml` | Linux VM provisioning (cloud-init) |
