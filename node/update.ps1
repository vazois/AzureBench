#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pull latest repo, copy scripts, and optionally run deploy commands.
    Reads manifest.json for source→destination mapping and runcmd definitions.

.EXAMPLE
    update.ps1 -Pull
    update.ps1 -Run
    update.ps1 -Pull -Run
#>
param(
    [switch]$Pull,
    [switch]$Copy,
    [switch]$Run,
    [switch]$RunOnly,
    [switch]$Force,
    [switch]$Help
)

if ($Help -or (-not $Pull -and -not $Copy -and -not $Run -and -not $RunOnly)) {
    Write-Host "Usage: update.ps1 [-Pull] [-Copy] [-Run] [-RunOnly] [-Force]"
    Write-Host ""
    Write-Host "Pull latest repo, copy scripts, and optionally run deploy commands."
    Write-Host "Reads manifest.json for source->destination mapping and runcmd definitions."
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Pull      Pull latest changes from git before copying"
    Write-Host "  -Copy      Copy scripts to deployed locations"
    Write-Host "  -Run       Copy scripts and execute the runcmd section from manifest"
    Write-Host "  -RunOnly   Execute runcmd without copying scripts"
    Write-Host "  -Force     Force pull (git reset --hard) instead of fast-forward"
    Write-Host "  -Help      Show this help message"
    return
}

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir = $ScriptDir
$Manifest = "$RepoDir/manifest.json"

if ($Pull) {
    Write-Host "Pulling latest from repo..."
    if ($Force) {
        $branch = git -C $RepoDir rev-parse --abbrev-ref HEAD 2>$null
        git -C $RepoDir fetch --all -q 2>$null
        git -C $RepoDir reset --hard "origin/$branch" -q 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Host "  WARNING: git force pull failed" -ForegroundColor Yellow }
    } else {
        git -C $RepoDir pull --ff-only -q 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Host "  WARNING: git pull failed (use -Force to reset)" -ForegroundColor Yellow }
    }
}

if (-not (Test-Path $Manifest)) {
    throw "ERROR: $Manifest not found"
}

$entries = Get-Content $Manifest -Raw | ConvertFrom-Json

# Copy scripts to deployed locations (skip with -RunOnly)
if (-not $RunOnly) {
    Write-Host "Copying scripts to deployed locations..."

    # Ensure target directories exist (derive from manifest destinations)
    $dirs = $entries.scripts | ForEach-Object { Split-Path $_.dst -Parent } | Sort-Object -Unique
    foreach ($dir in $dirs) {
        sudo mkdir -p $dir 2>$null
    }

    foreach ($entry in $entries.scripts) {
        $src = "$RepoDir/$($entry.src)"
        $dst = $entry.dst
        $mode = $entry.mode

        if (Test-Path $src) {
            sudo cp $src $dst
            sudo chmod $mode $dst
            Write-Host "  $dst" -ForegroundColor DarkGray
        } else {
            Write-Host "  SKIP: $($entry.src) (not found)" -ForegroundColor Yellow
        }
    }

    Write-Host "Scripts updated." -ForegroundColor Green
}

# Execute runcmd section if -Run or -RunOnly is passed
if ($Run -or $RunOnly) {
    if (-not $entries.runcmd) {
        Write-Host "No runcmd section in manifest. Skipping."
        return
    }

    # Build variable lookup from the vars section
    $vars = @{}
    if ($entries.PSObject.Properties['vars']) {
        $entries.vars.PSObject.Properties | ForEach-Object { $vars[$_.Name] = $_.Value }
        Write-Host ""
        Write-Host "Variables:" -ForegroundColor DarkGray
        $vars.GetEnumerator() | ForEach-Object { Write-Host "  $($_.Key) = $($_.Value)" -ForegroundColor DarkGray }
    }

    Write-Host ""
    Write-Host "Executing runcmd from manifest..."

    foreach ($cmd in $entries.runcmd) {
        $scriptName = $cmd.run
        $useSudo = $cmd.sudo
        $cmdArgs = $cmd.args
        $background = if ($cmd.PSObject.Properties['background']) { $cmd.background } else { $false }

        # Resolve ${varName} placeholders in args
        foreach ($key in $vars.Keys) {
            $pattern = [regex]::Escape("`${$key}")
            $cmdArgs = $cmdArgs -replace $pattern, $vars[$key]
        }

        # Resolve script path from the scripts section by matching filename
        $scriptEntry = $entries.scripts | Where-Object { $_.src -like "*$scriptName" } | Select-Object -First 1
        if (-not $scriptEntry -or -not (Test-Path $scriptEntry.dst)) {
            Write-Host "  ERROR: Cannot resolve script '$scriptName' from manifest" -ForegroundColor Red
            continue
        }

        $scriptPath = $scriptEntry.dst
        $runCmd = if ($useSudo) { "sudo $scriptPath $cmdArgs" } else { "$scriptPath $cmdArgs" }

        Write-Host "  -> $runCmd"
        if ($background) {
            $logFile = "/var/log/$($scriptName -replace '\.sh$','').log"
            bash -c "nohup $runCmd > $logFile 2>&1 &"
        } else {
            bash -c $runCmd
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  FAILED: $runCmd" -ForegroundColor Red
            }
        }
    }

    Write-Host "All runcmd steps complete." -ForegroundColor Green
}
