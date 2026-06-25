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
| `garnet-acc-subnet` | 10.5.1.0/24 | Data plane — accelerated networking for all VMSS |

Both server and client VMSS share the accelerated networking subnet. Peer discovery uses hostname prefixes to distinguish VMSS membership.

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

Two VMSS groups are required — one for **servers** (running the storage system under test) and one for **clients** (running the benchmark workload):

```powershell
# Server VMSS
az deployment group create `
  --resource-group vazois-garnet `
  --template-file vmss.bicep `
  --parameters @vmss-parameters.json `
  --parameters vmssName=server instanceCount=<n>

# Client VMSS
az deployment group create `
  --resource-group vazois-garnet `
  --template-file vmss.bicep `
  --parameters @vmss-parameters.json `
  --parameters vmssName=client instanceCount=<n>
```

VMs are provisioned via cloud-init with .NET SDKs, repos, and tooling pre-installed.

### 5. Manage Cluster

Start or stop the storage cluster on server VMs. Reads connection info from `benchmark/bench.conf`.

```powershell
# Start a 2-instance-per-node valkey cache cluster (clean deploy)
.\cluster.ps1 -Action start -System valkey -Template cache -ICount 2 -Clean

# Start garnet with replication (no cluster mode)
.\cluster.ps1 -Action start -System garnet -Template cache-replication -ICount 1 -NoCluster

# Stop the cluster
.\cluster.ps1 -Action stop -System valkey -ICount 2
```

The `start` action automatically starts instances and forms the cluster in one step. Use `-Clean` to wipe data directories before starting.

### 6. Run Benchmarks

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
HostCount=12            # number of VM instances (vm0..vm11)
Multiplier=1            # benchmark instances per VM

# Benchmark parameters
Host=10.5.1.4           # target server IP
Port=7000
Threads=16
Runtime=60
ClusterBench=true

# Optional workload tuning
# Op=SET                # operation type (GET, SET, MGET, MSET)
# Pool=false            # connection pool per worker
# Pipeline=false        # pipelined requests
# DbSize=1000000
# KeyLength=16
# ValueLength=128
# BatchSize=100
# ExtraArgs=--db-size 1000000
```

SSH keys are resolved automatically from `security/manifest.json` (falls back to `~/.ssh/id_ed25519`).

#### Running

```powershell
.\benchmark\resp-bench.ps1                                    # inline parallel, totals only
.\benchmark\resp-bench.ps1 -Detail                            # show per-instance results
.\benchmark\resp-bench.ps1 -Background                        # spawn Windows Terminal panes
.\benchmark\resp-bench.ps1 -ConfigFile .\custom.conf -Detail  # custom config
```

| Flag | Behavior |
|------|----------|
| *(none)* | Inline parallel execution, prints TOTAL only |
| `-Detail` | Adds per-instance breakdown to aggregation output |
| `-Background` | Spawns Windows Terminal tabs/panes (2 per tab) for visual inspection |

Before running benchmarks, the script probes the server and displays system info (name, version, OS, CPU count, port, uptime).

The script:
1. SSHs into each client VM and runs `Resp.benchmark` with the configured parameters
2. Output is tee'd to timestamped log files under `benchmark/results/<yyyyMMdd-HHmmss>/`
3. Polls log files until all instances report `Total throughput:` (or a timeout of `runtime + 120s`)
4. Aggregates results across all instances:

```
=== Aggregate Results (20260616-164500) ===
  vm0-myclient-0   1,234.56 Kops/sec |  0.450 GB/s data |  0.520 GB/s wire
  vm1-myclient-1     987.65 Kops/sec |  0.380 GB/s data |  0.440 GB/s wire
  ----------------------------------------------------------------------
  TOTAL              2,222.21 Kops/sec |  0.830 GB/s data |  0.960 GB/s wire
```

### 7. Update Nodes (Refresh Repos, Rebuild Systems)

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

# Refresh repos
pwsh .\update-nodes.ps1 --action refresh --rg garnet-bench --verbose --force

# install scripts
pwsh .\update-nodes.ps1 --action install --rg garnet-bench --verbose --force

```

**Notes:**
- Build branches are configured in `node/manifest.json` under the `vars` section (e.g., `serverBranch`, `clientBranch`) and automatically substituted during rebuild
- Supports multiple VMSS: `-VmssName server,client` or `-VmssName all`
- SSH keys automatically resolved from `security/manifest.json` (userKeys)
- Results reported per-instance with success/failure summary

### 8. Update Keys on Live VMSS (Optional)

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
| `cluster.ps1` | Cluster lifecycle management (start/stop via SSH) |
| `deploy-keys.ps1` | Key sync, Key Vault deployment, and live update |
| `deploy-network-resources.ps1` | Network deployment + param generation |
| `update-nodes.ps1` | SSH-based repo refresh, system rebuild, and initialization |
| `cloud-config-azurelinux.yml` | Linux VM provisioning (cloud-init) |
