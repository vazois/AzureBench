#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Controls cluster lifecycle (start/stop) on remote VMSS server instances via SSH.

.DESCRIPTION
    SSHs into the first server VM and invokes cluster-deploy.ps1 to manage
    the cluster across all discovered peers. The 'start' action automatically
    starts instances and forms the cluster (setup) in one step.

.EXAMPLE
    .\cluster.ps1 -Action start -System valkey -Template cache -ICount 2
    .\cluster.ps1 -Action start -System valkey -Template cache -ICount 2 -Clean
    .\cluster.ps1 -Action start -System garnet -Template cache-replication -ICount 1 -NoCluster
    .\cluster.ps1 -Action stop -System valkey -ICount 2
#>
param(
    [ValidateSet("start","stop")]
    [string]$Action,

    [ValidateSet("valkey","garnet")]
    [string]$System,

    [string]$Template,
    [Alias('Config')][string]$Conf,
    [int]$ICount = 1,
    [int]$Replicas = 0,
    [switch]$Clean,
    [switch]$NoCluster,
    [string]$ConfigFile = "$PSScriptRoot\benchmark\bench.conf",
    [string]$ServerHost,
    [string]$SshUser,
    [string]$SshKey,
    [switch]$Help
)

if ($Help -or -not $Action) {
    Write-Host "Usage: cluster.ps1 -Action <start|stop> -System <valkey|garnet> [options]"
    Write-Host ""
    Write-Host "Controls cluster lifecycle on remote VMSS server instances via SSH."
    Write-Host "SSHs into the server VM and runs cluster-deploy.ps1 to orchestrate."
    Write-Host ""
    Write-Host "Actions:"
    Write-Host "  start    Start instances + form cluster (start then setup)"
    Write-Host "  stop     Stop cluster instances on all server VMs"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -System      Target system: valkey or garnet (required)"
    Write-Host "  -Template    Config template name (required for start unless -Conf given)"
    Write-Host "  -Conf        Local config file path on THIS workstation; its content is shipped to the nodes (no git push needed)"
    Write-Host "  -ICount      Number of instances per VM (default: 1)"
    Write-Host "  -Replicas    Number of replicas per primary (default: 0)"
    Write-Host "  -Clean       Remove cluster directory before starting"
    Write-Host "  -NoCluster   Disable cluster mode (skip setup step)"
    Write-Host "  -ConfigFile  Path to bench.conf for SSH host/key resolution (default: bench.conf)"
    Write-Host "  -ServerHost  Override server SSH host (default: from bench.conf Host field)"
    Write-Host "  -SshUser     Override SSH user (default: from bench.conf or guser)"
    Write-Host "  -SshKey      Override SSH key path (default: from security/manifest.json)"
    return
}

$ErrorActionPreference = "Stop"

# --- Validate params ---
if (-not $System) { Write-Error "-System is required"; exit 1 }
if ($Action -eq "start" -and -not $Template -and -not $Conf) {
    Write-Error "-Template or -Conf is required for 'start'"; exit 1
}
if ($Template -and $Conf) {
    Write-Error "-Template and -Conf are mutually exclusive; specify only one"; exit 1
}

# --- Resolve -Conf as a LOCAL workstation file and base64-encode it for shipping ---
$confContent = ""
$confName = ""
if ($Conf) {
    $confPath = $Conf
    if (-not [System.IO.Path]::IsPathRooted($confPath)) {
        if (Test-Path $confPath) {
            $confPath = (Resolve-Path $confPath).Path
        } elseif (Test-Path (Join-Path $PSScriptRoot $Conf)) {
            $confPath = (Join-Path $PSScriptRoot $Conf)
        }
    }
    if (-not (Test-Path $confPath)) {
        Write-Error "-Conf file not found on this workstation: $Conf"; exit 1
    }
    $confName = Split-Path $confPath -Leaf
    $confBytes = [System.IO.File]::ReadAllBytes($confPath)
    $confContent = [Convert]::ToBase64String($confBytes)
}

# --- Load config file for defaults ---
$config = @{}
if (Test-Path $ConfigFile) {
    Get-Content $ConfigFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#")) {
            $parts = $line -split "=", 2
            if ($parts.Count -eq 2) {
                $config[$parts[0].Trim()] = $parts[1].Trim()
            }
        }
    }
}

# --- Resolve SSH key ---
if (-not $SshKey) {
    $manifestPath = Join-Path $PSScriptRoot "security\manifest.json"
    if (Test-Path $manifestPath) {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        $manifestBasePath = [Environment]::ExpandEnvironmentVariables($manifest.basePath)
        $candidates = $manifest.userKeys | ForEach-Object { Join-Path $manifestBasePath $_ }
        $SshKey = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $SshKey) {
        $SshKey = "$env:USERPROFILE\.ssh\id_ed25519"
    }
}
if (-not (Test-Path $SshKey)) {
    Write-Error "SSH key not found: $SshKey"
    exit 1
}

# --- Resolve SSH user and server host ---
if (-not $SshUser) { $SshUser = $config["SshUser"] ?? "guser" }
if (-not $ServerHost) { $ServerHost = $config["Host"] ?? "" }
if (-not $ServerHost) {
    Write-Error "No server host specified. Use -ServerHost or set Host= in bench.conf"
    exit 1
}

# --- Helper to run a remote command ---
$sshOpts = @('-i', $SshKey, '-o', 'StrictHostKeyChecking=no', '-o', 'ConnectTimeout=10', '-t')

function Invoke-Remote {
    param([string]$Cmd, [string]$Label)
    Write-Host "[$Label] $Cmd" -ForegroundColor Yellow
    Write-Host ""
    ssh @sshOpts "${SshUser}@${ServerHost}" "pwsh -c '$Cmd'"
    $code = $LASTEXITCODE
    Write-Host ""
    if ($code -ne 0) {
        Write-Host "[$Label] FAILED (exit code $code)" -ForegroundColor Red
        exit $code
    }
    Write-Host "[$Label] Done." -ForegroundColor Green
    Write-Host ""
}

# --- Summary ---
Write-Host "==== cluster ($Action) ====" -ForegroundColor Cyan
Write-Host "  Server:    $ServerHost"
Write-Host "  System:    $System"
if ($Conf)      { Write-Host "  Conf:      $Conf ($($confBytes.Length) bytes, shipped as $confName)" }
if ($Template)  { Write-Host "  Template:  $Template" }
Write-Host "  ICount:    $ICount"
if ($Replicas -gt 0) { Write-Host "  Replicas:  $Replicas" }
if ($Clean)     { Write-Host "  Clean:     True" }
if ($NoCluster) { Write-Host "  NoCluster: True" }
Write-Host ""

# --- Execute ---
switch ($Action) {
    "start" {
        # Step 1: Start instances
        $startCmd = "cluster-deploy.ps1 -Action start -System $System -ICount $ICount"
        if ($Template) { $startCmd += " -Template $Template" }
        if ($Conf) { $startCmd += " -ConfContent $confContent -ConfName $confName" }
        if ($Clean) { $startCmd += " -Clean" }
        if ($NoCluster) { $startCmd += " -NoCluster" }
        Invoke-Remote -Cmd $startCmd -Label "start"

        # Step 2: Form cluster (skip if NoCluster)
        if (-not $NoCluster) {
            $setupCmd = "cluster-deploy.ps1 -Action setup -System $System -ICount $ICount"
            if ($Replicas -gt 0) { $setupCmd += " -Replicas $Replicas" }
            Invoke-Remote -Cmd $setupCmd -Label "setup"
        }
    }

    "stop" {
        $stopCmd = "cluster-deploy.ps1 -Action stop -System $System -ICount $ICount"
        Invoke-Remote -Cmd $stopCmd -Label "stop"
    }
}

Write-Host "==== cluster ($Action) complete ====" -ForegroundColor Green
