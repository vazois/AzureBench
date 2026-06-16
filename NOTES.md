# VMSS Combined Deployment

Deploy Linux or Windows Virtual Machine Scale Sets with pre-configured tooling, .NET SDKs, and optional Key Vault integration for private repo access.

## Prerequisites

- Azure CLI (`az`) logged in
- Resource group with existing VNet, NSG, and Proximity Placement Group
- Parameters file (`vmss-parameters.json`) configured for your environment

---

## Deploy Key Vault (one-time)

```powershell
az deployment group create `
  --resource-group vazois-garnet `
  --template-file keyvault.bicep `
  --parameters keyVaultName=vazois-garnet-kv location=southcentralus
```

After creation, upload a GitHub PAT:
```powershell
.\New-GitHubPat.ps1 -RepoOwner vazois -RepoName "garnet,Scripts" -KeyVaultName vazois-garnet-kv
```

---

## Deploy VMSS

### Linux (Ubuntu 24.04)

```powershell
az deployment group create `
  --resource-group vazois-garnet `
  --template-file vmss.bicep `
  --parameters @vmss-parameters.json `
  --parameters vmssName=myUbuntuVmss `
               instanceCount=2 `
               operatingSystem=linux `
               vmSKU=Standard_F64s_v2 `
               osDiskType=Premium_LRS `
               keyVaultName=vazois-garnet-kv `
               linuxImage="{'publisher':'Canonical','offer':'ubuntu-24_04-lts','sku':'server','version':'latest'}"
```

### Linux (Azure Linux 3 — x64)

```powershell
az deployment group create `
  --resource-group vazois-garnet `
  --template-file vmss.bicep `
  --parameters @vmss-parameters.json `
  --parameters vmssName=myAzLinuxVmss `
               instanceCount=2 `
               operatingSystem=linux `
               vmSKU=Standard_F64s_v2 `
               osDiskType=Premium_LRS `
               keyVaultName=vazois-garnet-kv `
               linuxImage="{'publisher':'microsoftcblmariner','offer':'azure-linux-3','sku':'azure-linux-3-gen2','version':'latest'}"
```

### Linux (Azure Linux 3 — ARM64)

```powershell
az deployment group create `
  --resource-group vazois-garnet `
  --template-file vmss.bicep `
  --parameters @vmss-parameters.json `
  --parameters vmssName=myArmVmss `
               instanceCount=2 `
               operatingSystem=linux `
               vmSKU=Standard_B16ps_v2 `
               osDiskType=Premium_LRS `
               keyVaultName=vazois-garnet-kv `
               linuxImage="{'publisher':'microsoftcblmariner','offer':'azure-linux-3','sku':'azure-linux-3-arm64','version':'latest'}"
```

### Windows

```powershell
az deployment group create `
  --resource-group vazois-garnet `
  --template-file vmss.bicep `
  --parameters @vmss-parameters.json `
  --parameters vmssName=myWinVmss `
               instanceCount=2 `
               operatingSystem=windows `
               vmSKU=Standard_D4s_v3 `
               osDiskType=Premium_LRS `
               adminPassword='YourSecurePass123!' `
               keyVaultName=vazois-garnet-kv
```

> **Note:** `adminPassword` is only required for Windows. Linux uses SSH keys.  
> **Note:** `keyVaultName` is optional. Omit it to skip Key Vault role assignment and private repo cloning.

---

## Adding/Removing Repos to Clone

Edit the repo list in the appropriate cloud-config file:

- **Ubuntu:** `cloud-config.yml`
- **Azure Linux:** `cloud-config-azurelinux.yml`

Find the `/tmp/repos.txt` section under `write_files`:

```yaml
  - path: /tmp/repos.txt
    permissions: '0644'
    content: |
      public|https://github.com/org/public-repo.git|/home/guser/public-repo
      private|https://github.com/org/private-repo.git|/home/guser/private-repo
```

Each line has the format:
```
visibility|clone-url|target-path
```

- `public` — cloned without authentication
- `private` — cloned using the PAT from Key Vault

After editing, redeploy the VMSS to pick up changes (cloud-config is baked into the deployment as base64).

---

## Updating .NET SDK Versions

The .NET SDK channels are defined in the `install-dotnet.sh` script inside each cloud-config file.

Find the `CHANNELS` array:

```bash
CHANNELS=("8.0" "9.0" "10.0")
```

- Add a channel (e.g., `"11.0"`) to install the latest SDK for that major version
- Remove a channel to stop installing it

For **Windows**, edit `install-software.ps1`:

```powershell
$channels = @("8.0", "9.0", "10.0")
```

The installer always fetches the latest minor/patch for each channel.

---

## Helper Scripts (Available on Linux VMs)

After deployment, these scripts are available on each VM for manual re-execution:

| Command | Description |
|---------|-------------|
| `install-dotnet` | Re-run .NET SDK installation |
| `setup-repos [vault-name] [secret-name]` | Re-run repo cloning |
| `ghclone <vault-name> <repo-url> [path]` | Clone a single private repo using Key Vault PAT |

---

## Connecting to VMs

### Linux (SSH with keys)
```bash
ssh guser@<public-ip>
```

### Linux (Azure AD)
```bash
az ssh vm --resource-group vazois-garnet --name <vmss-name> --prefer-private-ip
```

### Windows (RDP)
Connect via RDP to the public IP with `guser` / your admin password.

### Windows (Azure AD)
Sign in with your Azure AD credentials via RDP.

---

## Files Overview

| File | Purpose |
|------|---------|
| `vmss.bicep` | Main VMSS deployment (Linux + Windows) |
| `vmss-parameters.json` | Shared infra parameters (VNet, NSG, etc.) |
| `keyvault.bicep` | Key Vault deployment (one-time) |
| `cloud-config.yml` | Cloud-init for Ubuntu |
| `cloud-config-azurelinux.yml` | Cloud-init for Azure Linux (tdnf) |
| `install-software.ps1` | Windows provisioning script |
| `New-GitHubPat.ps1` | PAT creation + Key Vault upload helper |
