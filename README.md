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

Creates NSG, VNet, and a proximity placement group. Auto-generates `vmss-parameters.json` with resource IDs.

#### Actions

| Action | Command | Description |
|--------|---------|-------------|
| `deploy` (default) | `.\deploy-network-resources.ps1` | Deploys network resources and generates `vmss-parameters.json` |
| `stage` | `.\deploy-network-resources.ps1 -Action stage -rg <rg>` | Queries existing resources in the resource group and generates `vmss-parameters.json` (no deployment) |

The VNet contains three subnets:

| Subnet | Prefix | Purpose |
|--------|--------|---------|
| `garnet-subnet` | 10.5.0.0/24 | Management — public IPs, SSH access from corpnet |
| `garnet-acc-subnet` | 10.5.1.0/24 | Server data plane — accelerated networking for server VMSS |
| `garnet-client-subnet` | 10.5.2.0/24 | Client data plane — accelerated networking for client/benchmark VMSS |

When deploying a VMSS, use `vmssRole=server` (default) to attach to 10.5.1.X or `vmssRole=client` for 10.5.2.X.

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

Two VMSS groups are required — one for **servers** (running the storage system under test) and one for **clients** (running the benchmark workload). The deployment will prompt for `vmssRole` to assign the correct data subnet:

```powershell
# Server VMSS (10.5.1.X data plane)
az deployment group create `
  --resource-group vazois-garnet `
  --template-file vmss.bicep `
  --parameters @vmss-parameters.json `
  --parameters vmssName=server instanceCount=<n> vmssRole=server

# Client VMSS (10.5.2.X data plane)
az deployment group create `
  --resource-group vazois-garnet `
  --template-file vmss.bicep `
  --parameters @vmss-parameters.json `
  --parameters vmssName=client instanceCount=<n> vmssRole=client
```

> **Note:** `vmssRole` is a required parameter with no default. If not passed inline, the CLI will prompt you to choose between `server` and `client`.

VMs are provisioned via cloud-init with .NET SDKs, repos, and tooling pre-installed.

### 5. Run Benchmarks

The `benchmark/` folder contains the benchmark launcher and its configuration:

| File | Purpose |
|------|---------|
| `benchmark/resp-bench.ps1` | Launches [Resp.benchmark](https://github.com/microsoft/garnet) across client VMs via SSH |
| `benchmark/bench.conf` | Key-value config for SSH targets, benchmark parameters, and workload tuning |
| `benchmark/results/` | Auto-generated per-run output (git-ignored) |

#### Configuration (`bench.conf`)

```ini
# SSH connection
SshUser=guser
SshHost=[vm0.myclient.southcentralus.cloudapp.azure.com]
SshCount=12          # number of VMs (vm0..vm11)
Multiplier=1         # instances per VM

# Benchmark parameters
Host=10.5.1.4        # target server IP
Port=7000
Threads=16
Runtime=60
ClusterBench=true

# Optional
# DbSize=1000000
# KeyLength=16
# ValueLength=128
# BatchSize=100
# ExtraArgs=--db-size 1000000
```

SSH keys are resolved automatically from `security/manifest.json` (falls back to `~/.ssh/id_ed25519`).

#### Running

```powershell
.\benchmark\resp-bench.ps1                          # uses default bench.conf
.\benchmark\resp-bench.ps1 -ConfigFile .\custom.conf # custom config
```

The script:
1. Opens Windows Terminal tabs/panes — one per SSH session (2 panes per tab)
2. Each pane SSHs into a client VM and runs `Resp.benchmark` with the configured parameters
3. Output is tee'd to timestamped log files under `benchmark/results/<yyyyMMdd-HHmmss>/`
4. Polls log files until all instances report `Total throughput:` (or a timeout of `runtime + 120s`)
5. Aggregates results across all instances, printing per-instance and total throughput:

```
=== Aggregate Results (20260616-164500) ===
  vm0-myclient-0   1,234.56 Kops/sec |  0.450 GB/s data |  0.520 GB/s wire
  vm1-myclient-1     987.65 Kops/sec |  0.380 GB/s data |  0.440 GB/s wire
  ----------------------------------------------------------------------
  TOTAL              2,222.21 Kops/sec |  0.830 GB/s data |  0.960 GB/s wire
```

### 6. Update Nodes (Refresh Repos, Rebuild Systems)

SSH into VMSS instances to refresh repositories, rebuild systems, or re-run initialization workflows.

#### Actions

| Action | Description |
|--------|-------------|
| `refresh` (default) | Git pull all repos (garnet, valkey, dragonfly, redis, memtier, AzureBench) |
| `rebuild` | Git pull + rebuild specified system (requires `-System` parameter) |
| `deploy` | Git pull AzureBench + run full deployment workflow from scratch |
| `install` | Git pull AzureBench + copy scripts to system paths only |

#### Examples

```powershell
# List VMSS in resource group and prompt for selection, then refresh all repos
.\update-nodes.ps1 -rg vazois-garnet

# Refresh repos on specific VMSS
.\update-nodes.ps1 -rg vazois-garnet -VmssName server

# Rebuild garnet on multiple VMSS (pulls main, builds, installs to /usr/local/bin)
.\update-nodes.ps1 -rg vazois-garnet -VmssName server,client -Action rebuild -System garnet

# Rebuild valkey with specific version (uses args from manifest.json: "valkey 9.0")
.\update-nodes.ps1 -rg vazois-garnet -VmssName server -Action rebuild -System valkey

# Run full deployment workflow from scratch on all VMSS
.\update-nodes.ps1 -rg vazois-garnet -VmssName all -Action deploy

# Update scripts only (no rebuild)
.\update-nodes.ps1 -rg vazois-garnet -VmssName server -Action install
```

**Notes:**
- Rebuild arguments (e.g., branch names, build flags) are read from `node/manifest.json` to ensure consistency
- Supports multiple VMSS: `-VmssName server,client` or `-VmssName all`
- SSH keys automatically resolved from `security/manifest.json` (userKeys)
- Results reported per-instance with success/failure summary

### 7. Update Keys on Live VMSS (Optional)

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
| `benchmark/` | Benchmark launcher, config, and results |
| `deploy-keys.ps1` | Key sync, Key Vault deployment, and live update |
| `deploy-network-resources.ps1` | Network deployment + param generation |
| `update-nodes.ps1` | SSH-based repo refresh, system rebuild, and initialization |
| `cloud-config-azurelinux.yml` | Linux VM provisioning (cloud-init) |
