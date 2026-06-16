# AzureBench

Automated deployment of benchmarking environments on Azure using VMSS (Virtual Machine Scale Sets).

## Setup Steps

### 1. Prerequisites

- Azure CLI (`az`) logged in
- PowerShell 7+
- Resource group created (default: `vazois-garnet`)
- SSH key pair for **intra-VMSS** access (VM-to-VM communication within a scale set, e.g., `id_ed25519_vmss`)
- SSH key pair(s) for **inter-VMSS** access (your desktop/notebook connecting to VMs, e.g., `id_ed12182024_desktop`)

### 2. Deploy Network Resources

```powershell
.\deploy-network-resources.ps1
```

Creates NSGs, VNet (with two subnets), and a proximity placement group. Auto-generates `vmss-parameters.json` with resource IDs.

### 3. Configure SSH Keys and Key Vault

Edit `security/manifest.json` to declare your SSH key names and base path:

```json
{
    "basePath": "%USERPROFILE%\\.ssh",
    "userKeys": ["id_ed12182024_desktop", "id_ed121824_notebook"],
    "vmKeys": "id_ed25519_vmss"
}
```

- **`userKeys`** — your personal keys for SSH access into VMs (public keys deployed to `authorized_keys`)
- **`vmKeys`** — the VMSS inter-node key (public key deployed to VMs, private key uploaded to Key Vault for VM-to-VM SSH)

#### Actions

| Action | Command | Description |
|--------|---------|-------------|
| `deploy` (default) | `.\deploy-keys.ps1` | Copies `.pub` files to `security/`, updates `vmss-parameters.json`, deploys Key Vault, and uploads VMSS private key |
| `vault` | `.\deploy-keys.ps1 -Action vault` | Only deploys Key Vault and uploads the VMSS private key. Prompts to reuse an existing vault or create a new one |
| `sync` | `.\deploy-keys.ps1 -Action sync -rg <rg>` | Discovers existing Key Vault in the resource group and updates `manifest.json` + `vmss-parameters.json` |
| `update` | `.\deploy-keys.ps1 -Action update -VmssName <name>` | Pushes public keys to running VMSS instances via `az vmss run-command` (no redeployment) |

#### Key Vault Naming

Vault names are auto-generated as `kv-{yyyyMMddHHmmss}` to avoid global name collisions. The name is saved to `manifest.json` after creation. If a soft-deleted vault with the same name exists, the script will attempt to purge it or generate a new name.

#### Examples

```powershell
# Full deploy (keys + Key Vault) to default resource group
.\deploy-keys.ps1

# Deploy Key Vault only to a specific resource group
.\deploy-keys.ps1 -Action vault -rg garnet-bench

# Discover existing Key Vault and update parameters
.\deploy-keys.ps1 -Action sync -rg garnet-bench

# Push keys to live VMSS without redeployment
.\deploy-keys.ps1 -Action update -VmssName myVmss -rg garnet-bench
```

### 4. Deploy VMSS

Two VMSS groups are required — one for **servers** (running the storage system under test) and one for **clients** (running the benchmark workload).

```powershell
# Server VMSS
az deployment group create `
  --resource-group vazois-garnet `
  --template-file vmss.bicep `
  --parameters @vmss-parameters.json `
  --parameters vmssName=server instanceCount=<n> vmSKU=<sku>

# Client VMSS (for running benchmarks)
az deployment group create `
  --resource-group vazois-garnet `
  --template-file vmss.bicep `
  --parameters @vmss-parameters.json `
  --parameters vmssName=client instanceCount=<n> vmSKU=<sku>
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
| `security/` | SSH key manifest, public keys, and Key Vault template |
| `node/` | Node-side scripts (deploy, cluster, system, benchmark) |
| `deploy-keys.ps1` | Key sync, Key Vault deployment, and live update |
| `deploy-network-resources.ps1` | Network deployment + param generation |
| `cloud-config-azurelinux.yml` | Linux VM provisioning (cloud-init) |
