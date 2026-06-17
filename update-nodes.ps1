#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Updates and rebuilds software on VMSS nodes via SSH.

.DESCRIPTION
    Connects to VMSS instances via SSH to refresh repos, rebuild systems, or re-run initialization.
    Supports multiple VMSS in a resource group with auto-discovery and validation.

.PARAMETER rg
    Azure resource group name (required).

.PARAMETER VmssName
    VMSS name(s) to target. Accepts single name or comma-separated list.
    If omitted, script lists all VMSS and prompts for selection.

.PARAMETER Action
    Action to perform:
    - refresh (default): git pull all repos
    - rebuild: git pull + rebuild specified system (requires -System)
    - deploy: git pull AzureBench + run full deployment workflow
    - install: git pull AzureBench + copy scripts only

.PARAMETER System
    System to rebuild (required when Action=rebuild).
    Valid: garnet, valkey, resp-bench, memtier

.PARAMETER SshUser
    SSH username (default: guser)

.PARAMETER Parallel
    Execute commands in parallel across all instances (otherwise sequential)

.EXAMPLE
    # List VMSS and prompt for selection, then refresh all repos
    .\update-nodes.ps1 -rg vazois-garnet

    # Refresh specific VMSS
    .\update-nodes.ps1 -rg vazois-garnet -VmssName server

    # Rebuild garnet on multiple VMSS
    .\update-nodes.ps1 -rg vazois-garnet -VmssName server,client -Action rebuild -System garnet

    # Re-run initialization on all VMSS
    .\update-nodes.ps1 -rg vazois-garnet -VmssName all -Action reinit
#>

param(
    [string]$rg,

    [string]$VmssName,

    [ValidateSet('refresh', 'rebuild', 'deploy', 'install', 'ping')]
    [string]$Action = 'refresh',

    [ValidateSet('garnet', 'valkey', 'resp-bench', 'memtier')]
    [string]$System,

    [string]$SshUser = 'guser',

    [switch]$Parallel,

    [switch]$Help
)

if ($Help -or -not $rg) {
    Write-Host "Usage: update-nodes.ps1 -rg <resource-group> [options]" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Updates and rebuilds software on VMSS nodes via SSH."
    Write-Host ""
    Write-Host "Required Parameters:"
    Write-Host "  -rg <name>          Azure resource group name"
    Write-Host ""
    Write-Host "Optional Parameters:"
    Write-Host "  -VmssName <name>    VMSS name(s) to target (comma-separated or 'all')"
    Write-Host "                      If omitted, script prompts for selection"
    Write-Host "  -Action <action>    Action to perform (default: refresh)"
    Write-Host "                      refresh        - git pull all repos"
    Write-Host "                      rebuild        - git pull + rebuild system (requires -System)"
    Write-Host "                      deploy         - git pull + run full deployment workflow"
    Write-Host "                      install        - git pull + copy scripts only"
    Write-Host "  -System <name>      System to rebuild: garnet, valkey, resp-bench, memtier"
    Write-Host "                      Required when -Action rebuild"
    Write-Host "  -SshUser <user>     SSH username (default: guser)"
    Write-Host "  -Parallel           Execute in parallel across instances"
    Write-Host "  -Help               Show this help message"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  .\update-nodes.ps1 -rg vazois-garnet"
    Write-Host "  .\update-nodes.ps1 -rg vazois-garnet -VmssName server -Action rebuild -System garnet"
    Write-Host "  .\update-nodes.ps1 -rg vazois-garnet -VmssName server,client -Action refresh"
    Write-Host ""
    Write-Host "For detailed help: Get-Help .\update-nodes.ps1 -Detailed"
    Write-Host ""
    return
}

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Validate Action and System parameter combination
if ($Action -eq 'rebuild' -and -not $System) {
    Write-Error "Action 'rebuild' requires -System parameter (garnet, valkey, resp-bench, or memtier)"
    exit 1
}

# --- VMSS Discovery & Selection ---
Write-Host "`n=== Discovering VMSS in resource group '$rg' ===" -ForegroundColor Cyan

$allVmssJson = az vmss list --resource-group $rg --query '[].name' -o json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $allVmssJson) {
    Write-Error "Failed to list VMSS in resource group '$rg'. Ensure the resource group exists and you're logged in."
    exit 1
}

$allVmss = $allVmssJson | ConvertFrom-Json
if ($allVmss.Count -eq 0) {
    Write-Error "No VMSS found in resource group '$rg'."
    exit 1
}

$targetVmss = @()

if (-not $VmssName) {
    # Prompt user to select
    Write-Host "`nAvailable VMSS:"
    for ($i = 0; $i -lt $allVmss.Count; $i++) {
        Write-Host "  [$i] $($allVmss[$i])"
    }
    Write-Host ""
    $selection = Read-Host "Select VMSS (comma-separated indices/names, or 'all')"

    if ($selection -eq 'all') {
        $targetVmss = $allVmss
    } else {
        $parts = $selection -split ',' | ForEach-Object { $_.Trim() }
        foreach ($part in $parts) {
            if ($part -match '^\d+$') {
                $idx = [int]$part
                if ($idx -ge 0 -and $idx -lt $allVmss.Count) {
                    $targetVmss += $allVmss[$idx]
                } else {
                    Write-Error "Invalid index: $idx"
                    exit 1
                }
            } else {
                if ($part -in $allVmss) {
                    $targetVmss += $part
                } else {
                    Write-Error "VMSS '$part' not found in resource group '$rg'"
                    exit 1
                }
            }
        }
    }
} else {
    # Validate provided VMSS names
    if ($VmssName -eq 'all') {
        $targetVmss = $allVmss
    } else {
        $targetVmss = $VmssName -split ',' | ForEach-Object { $_.Trim() }
        foreach ($vmss in $targetVmss) {
            if ($vmss -notin $allVmss) {
                Write-Error "VMSS '$vmss' not found in resource group '$rg'. Available: $($allVmss -join ', ')"
                exit 1
            }
        }
    }
}

if ($targetVmss.Count -eq 0) {
    Write-Error "No VMSS selected."
    exit 1
}

Write-Host "Target VMSS: $($targetVmss -join ', ')" -ForegroundColor Green

# --- SSH Key Resolution ---
$sshKey = $null
$manifestPath = Join-Path $scriptDir "security\manifest.json"

if (Test-Path $manifestPath) {
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $manifestBasePath = [Environment]::ExpandEnvironmentVariables($manifest.basePath)
    $candidates = $manifest.userKeys | ForEach-Object { Join-Path $manifestBasePath $_ }
    $sshKey = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}

if (-not $sshKey) {
    # Fallback to default
    $defaultKey = Join-Path $env:USERPROFILE ".ssh\id_ed25519"
    if (Test-Path $defaultKey) {
        $sshKey = $defaultKey
    } else {
        Write-Error "No SSH key found. Checked manifest.json and $defaultKey"
        exit 1
    }
}

Write-Host "Using SSH key: $sshKey" -ForegroundColor DarkGray

# --- Build SSH Command based on Action ---
function Get-SshCommand {
    param([string]$Action, [string]$System)

    switch ($Action) {
        'refresh' {
            # Read repos.txt to get all repo paths
            $reposFile = Join-Path $scriptDir "node\deploy\repos.txt"
            if (-not (Test-Path $reposFile)) {
                Write-Error "repos.txt not found at $reposFile"
                exit 1
            }

            $repoPaths = Get-Content $reposFile | ForEach-Object {
                if ($_ -match '^\s*$' -or $_ -match '^\s*#') { return }
                $parts = $_ -split '\|'
                if ($parts.Count -ge 3) { $parts[2].Trim() }
            } | Where-Object { $_ }

            $pullCommands = $repoPaths | ForEach-Object {
                "cd $_ && git pull --ff-only 2>&1 | sed 's/^/[$([System.IO.Path]::GetFileName($_))]: /'"
            }

            return $pullCommands -join '; '
        }

        'rebuild' {
            # Read manifest.json to get build arguments
            $manifestFile = Join-Path $scriptDir "node\manifest.json"
            if (-not (Test-Path $manifestFile)) {
                Write-Error "node/manifest.json not found"
                exit 1
            }

            $nodeManifest = Get-Content $manifestFile -Raw | ConvertFrom-Json
            $buildEntry = $nodeManifest.runcmd | Where-Object {
                $_.run -eq 'build.sh' -and $_.args -match "^$System\b"
            } | Select-Object -First 1

            if (-not $buildEntry) {
                Write-Error "No build entry found in manifest for system '$System'"
                exit 1
            }

            $buildArgs = $buildEntry.args

            # Map system to repo (resp-bench is built from garnet)
            $repoName = switch ($System) {
                'resp-bench' { 'garnet' }  # resp-bench is part of garnet repo
                default      { $System }
            }

            # Get repo path from repos.txt
            $reposFile = Join-Path $scriptDir "node\deploy\repos.txt"
            $repoPath = Get-Content $reposFile | ForEach-Object {
                if ($_ -match "/$repoName\.git\|(.+)$" -or $_ -match "/$repoName\|(.+)$") {
                    return $Matches[1].Trim()
                }
            } | Select-Object -First 1

            if (-not $repoPath) {
                Write-Error "Could not find repo path for '$repoName' in repos.txt"
                exit 1
            }

            return "cd $repoPath && echo '[git pull]' && git pull --ff-only && echo '[build]' && sudo /opt/deploy-actions/build.sh $buildArgs"
        }

        'deploy' {
            return "pwsh /home/$SshUser/AzureBench/node/update.ps1 -Pull -Run"
        }

        'install' {
            return "pwsh /home/$SshUser/AzureBench/node/update.ps1 -Pull -Copy"
        }

        'ping' {
            return "echo pong && hostname"
        }
    }
}

$sshCommand = Get-SshCommand -Action $Action -System $System

Write-Host "`n=== SSH Command ===" -ForegroundColor Cyan
Write-Host $sshCommand -ForegroundColor DarkGray
Write-Host ""

# --- Execute on all VMSS ---
$allResults = @()
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($vmss in $targetVmss) {
    Write-Host "`n=== Processing VMSS: $vmss ===" -ForegroundColor Cyan

    # Get instance public IPs
    $ipsJson = az vmss list-instance-public-ips `
        --resource-group $rg `
        --name $vmss `
        --query '[].{instance:name, ip:ipAddress}' -o json 2>$null

    if ($LASTEXITCODE -ne 0 -or -not $ipsJson) {
        Write-Warning "Failed to get public IPs for VMSS '$vmss'. Skipping."
        continue
    }

    $instances = $ipsJson | ConvertFrom-Json

    if ($instances.Count -eq 0) {
        Write-Warning "No instances with public IPs found in VMSS '$vmss'. Skipping."
        continue
    }

    Write-Host "Found $($instances.Count) instance(s) with public IPs" -ForegroundColor Yellow

    # Execute SSH command on each instance
    $sshOpts = @('-n', '-o', 'ConnectTimeout=10', '-o', 'StrictHostKeyChecking=no', '-o', 'BatchMode=yes')
    $totalInstances = $instances.Count

    if ($Parallel) {
        # Parallel execution using ForEach-Object -Parallel
        Write-Host "Running in parallel mode ($totalInstances instances)..." -ForegroundColor Magenta

        $results = $instances | ForEach-Object -Parallel {
            $instance = $_
            $ip = $instance.ip
            $instanceName = $instance.instance

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $outputText = ""
            $success = $false

            try {
                $output = ssh -i $using:sshKey $using:sshOpts "${using:SshUser}@${ip}" $using:sshCommand 2>&1
                $exitCode = $LASTEXITCODE
                $outputText = $output -join "`n"
                $success = ($exitCode -eq 0)
            } catch {
                $outputText = $_.Exception.Message
            }
            $sw.Stop()
            $duration = $sw.Elapsed.ToString('mm\:ss\.ff')

            $status = if ($success) { "SUCCESS" } else { "FAILED" }
            Write-Host "  [done] $instanceName ($ip) - $status [$duration]" -ForegroundColor $(if ($success) { 'Green' } else { 'Red' })

            [PSCustomObject]@{
                Vmss     = $using:vmss
                Instance = $instanceName
                IP       = $ip
                Success  = $success
                Output   = $outputText
                Duration = $duration
            }
        } -ThrottleLimit $totalInstances

        # Print results after all complete
        $idx = 0
        foreach ($r in $results) {
            $idx++
            Write-Host "`n  $idx/$totalInstances >>> $($r.Instance) ($($r.IP)) [$($r.Duration)]" -ForegroundColor Yellow
            if ($r.Success) {
                Write-Host "  Status: SUCCESS" -ForegroundColor Green
                if ($r.Output) {
                    $r.Output -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
                }
            } else {
                Write-Host "  Status: FAILED" -ForegroundColor Red
                if ($r.Output) {
                    $r.Output -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
                }
            }
        }

        $allResults += $results
    } else {
        # Sequential execution
        $instanceIndex = 0

        foreach ($instance in $instances) {
            $instanceIndex++
            $ip = $instance.ip
            $instanceName = $instance.instance

            Write-Host "`n  $instanceIndex/$totalInstances >>> $instanceName ($ip)" -ForegroundColor Yellow

            $result = @{
                Vmss     = $vmss
                Instance = $instanceName
                IP       = $ip
                Success  = $false
                Output   = ""
                Duration = ""
            }

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $output = ssh -i $sshKey @sshOpts "${SshUser}@${ip}" $sshCommand 2>&1
                $exitCode = $LASTEXITCODE

                $result.Output = $output -join "`n"

                if ($exitCode -eq 0) {
                    $result.Success = $true
                } else {
                    Write-Host "  Status: FAILED (exit code: $exitCode)" -ForegroundColor Red
                }
            } catch {
                $result.Output = $_.Exception.Message
            }
            $sw.Stop()
            $result.Duration = $sw.Elapsed.ToString('mm\:ss\.ff')

            if ($result.Success) {
                Write-Host "  Status: SUCCESS [$($result.Duration)]" -ForegroundColor Green
                if ($output) {
                    $output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
                }
            } elseif (-not $result.Success -and $result.Output) {
                Write-Host "  [$($result.Duration)]" -ForegroundColor DarkGray
                $result.Output -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
            } else {
                Write-Host "  Status: ERROR [$($result.Duration)] - $($result.Output)" -ForegroundColor Red
            }

            $allResults += [PSCustomObject]$result
        }
    }
}

# --- Summary ---
$stopwatch.Stop()
$elapsed = $stopwatch.Elapsed
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Elapsed: $($elapsed.ToString('mm\:ss\.ff'))" -ForegroundColor DarkGray

$successCount = ($allResults | Where-Object { $_.Success }).Count
$failCount = $allResults.Count - $successCount

Write-Host "Total instances: $($allResults.Count)"
Write-Host "  Success: $successCount" -ForegroundColor Green
Write-Host "  Failed:  $failCount" -ForegroundColor $(if ($failCount -gt 0) { 'Red' } else { 'Gray' })

if ($failCount -gt 0) {
    Write-Host "`nFailed instances:"
    $allResults | Where-Object { -not $_.Success } | ForEach-Object {
        Write-Host "  $($_.Vmss)/$($_.Instance) ($($_.IP))" -ForegroundColor Red
    }
}

Write-Host ""

exit $(if ($failCount -gt 0) { 1 } else { 0 })
