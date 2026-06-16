# Install Git silently
winget install --id Git.Git --silent --accept-package-agreements --accept-source-agreements

# Install .NET SDK versions using dotnet-install.ps1
$dotnetInstallScript = "$env:TEMP\dotnet-install.ps1"
Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $dotnetInstallScript

$channels = @("8.0", "9.0", "10.0")
foreach ($channel in $channels) {
    Write-Host "Installing .NET SDK channel $channel (latest)"
    & $dotnetInstallScript -Channel $channel -InstallDir 'C:\Program Files\dotnet'
}

# Ensure dotnet is on PATH for all users
$dotnetPath = 'C:\Program Files\dotnet'
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($machinePath -notlike "*$dotnetPath*") {
    [Environment]::SetEnvironmentVariable('Path', "$machinePath;$dotnetPath", 'Machine')
}
