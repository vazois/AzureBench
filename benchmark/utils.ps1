# Shared utility functions for benchmark scripts

function Wait-ParallelJob {
    <#
    .SYNOPSIS
        Displays a progress bar while waiting for a parallel job to complete.
    .PARAMETER Job
        The job object returned by ForEach-Object -Parallel -AsJob.
    .PARAMETER Progress
        A synchronized hashtable with a 'done' key tracking completed items.
    .PARAMETER Total
        Total number of items being processed.
    .PARAMETER Stopwatch
        A running Stopwatch for elapsed time display.
    .PARAMETER Label
        Text label shown before the progress bar (e.g., "Loading", "Running").
    #>
    param(
        [Parameter(Mandatory)]$Job,
        [Parameter(Mandatory)][hashtable]$Progress,
        [Parameter(Mandatory)][int]$Total,
        [Parameter(Mandatory)][System.Diagnostics.Stopwatch]$Stopwatch,
        [string]$Label = "Running"
    )
    $barWidth = 30
    $fillChar = ([char]0x2588).ToString()
    $emptyChar = ([char]0x2591).ToString()

    while ($Job.State -eq 'Running') {
        $done = $Progress.done
        $filled = [math]::Floor(($done / $Total) * $barWidth)
        $empty = $barWidth - $filled
        $bar = $fillChar * $filled + $emptyChar * $empty
        $elapsed = $Stopwatch.Elapsed.ToString('mm\:ss')
        Write-Host "`r  $Label... [$bar] $done/$Total ($elapsed)" -NoNewline
        Start-Sleep -Milliseconds 250
    }
    # Final bar at 100%
    $bar = $fillChar * $barWidth
    $elapsed = $Stopwatch.Elapsed.ToString('mm\:ss')
    Write-Host "`r  $Label... [$bar] $Total/$Total ($elapsed)" -NoNewline
    Write-Host ""
}

function Get-BenchmarkConfig {
    <#
    .SYNOPSIS
        Probes benchmark configuration by running a short test on one host and parsing the config block.
    .PARAMETER BenchCmd
        The full benchmark command string.
    .PARAMETER SshKey
        Path to SSH private key.
    .PARAMETER SshUser
        SSH username.
    .PARAMETER ProbeHost
        The SSH host to run the probe on.
    .PARAMETER Runtime
        Actual runtime value to display (probe overrides to 1s).
    .PARAMETER DbSize
        Actual DbSize value to display (probe overrides to 1).
    .RETURNS
        Hashtable with ConfigBlock (string[]) and WorkersPerInstance (int), or $null if probe fails.
    #>
    param(
        [Parameter(Mandatory)][string]$BenchCmd,
        [Parameter(Mandatory)][string]$SshKey,
        [Parameter(Mandatory)][string]$SshUser,
        [Parameter(Mandatory)][string]$ProbeHost,
        [string]$Runtime = "60",
        [string]$DbSize = ""
    )

    $probeOpts = @('-n', '-o', 'ConnectTimeout=10', '-o', 'StrictHostKeyChecking=no', '-o', 'BatchMode=yes')

    # Build probe command with short runtime + small dbsize
    $probeCmd = $BenchCmd -replace '--runtime\s+\d+', '--runtime 1'
    $probeCmd = $probeCmd -replace '--dbsize\s+\d+', '--dbsize 1'
    if ($probeCmd -notmatch '--dbsize') { $probeCmd += ' --dbsize 1' }

    Write-Host "Probing benchmark configuration..." -ForegroundColor DarkGray
    $probeOutput = ssh -i $SshKey @probeOpts "${SshUser}@${ProbeHost}" $probeCmd 2>&1

    # Parse config block between === lines
    $configBlock = @()
    $inConfig = $false
    foreach ($line in $probeOutput) {
        $lineStr = "$line"
        if ($lineStr -match '={3,}.*[Cc]onfiguration') {
            $inConfig = $true
            $configBlock += $lineStr
        } elseif ($inConfig -and $lineStr -match '^={3,}\s*$') {
            $configBlock += $lineStr
            break
        } elseif ($inConfig) {
            $configBlock += $lineStr
        }
    }

    if ($configBlock.Count -eq 0) { return $null }

    # Fix values back to actual (probe uses --runtime 1, --dbsize 1)
    $fixedBlock = $configBlock | ForEach-Object {
        $line = $_ -replace 'Runtime:\s*1s', "Runtime: ${Runtime}s"
        $line -replace 'DB Size:\s*\d+', "DB Size: $(if ($DbSize) { $DbSize } else { '0' })"
    }

    # Extract workers per instance
    $workersPerInstance = 0
    $configBlock | ForEach-Object {
        if ($_ -match 'Workers:\s*(\d+)') {
            $workersPerInstance = [int]$Matches[1]
        }
    }

    return @{
        ConfigBlock       = $fixedBlock
        WorkersPerInstance = $workersPerInstance
    }
}

function Show-BenchmarkConfig {
    param(
        [string]$BenchCmd,
        [string]$SshKey,
        [string]$SshUser,
        [string]$ProbeHost,
        [string]$Runtime,
        [string]$DbSize,
        [int]$Threads
    )

    $probeResult = Get-BenchmarkConfig -BenchCmd $BenchCmd -SshKey $SshKey -SshUser $SshUser -ProbeHost $ProbeHost -Runtime $Runtime -DbSize $DbSize

    if ($probeResult) {
        Write-Host ""
        $probeResult.ConfigBlock | ForEach-Object { Write-Host $_ -ForegroundColor Cyan }
        Write-Host ""
        $workersPerInstance = $probeResult.WorkersPerInstance
    } else {
        Write-Host "=== Benchmark Configuration ===" -ForegroundColor Cyan
        Write-Host "  Command    : $BenchCmd"
        Write-Host "===============================" -ForegroundColor Cyan
        Write-Host ""
        $workersPerInstance = [int]$Threads
    }

    return $workersPerInstance
}
