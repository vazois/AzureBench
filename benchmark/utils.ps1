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
