param (
    [string]$ContainerName
)

$ErrorActionPreference = 'Continue'
$runnerOs = $Env:RUNNER_OS ?? "Linux"

if ($runnerOs -eq "Linux") {
    if (-not $ContainerName) {
        Write-Output "No container name supplied, nothing to clean up"
        return
    }

    Write-Output "Killing Docker container $ContainerName"
    docker kill $ContainerName 2>$null

    Write-Output "Removing Docker container $ContainerName"
    docker rm $ContainerName 2>$null
}
elseif ($runnerOs -eq "Windows") {
    if ($ContainerName) {
        Write-Output "Removing WSL Docker container $ContainerName"
        if ($Env:WSL_DISTRIBUTION -and $Env:WSL_TOOLS_MODULE_PATH) {
            Import-Module $Env:WSL_TOOLS_MODULE_PATH -Force
            Invoke-Wsl -Command "docker rm --force $ContainerName 2>/dev/null || true"
        }
    }
}
else {
    Write-Output "$runnerOs not supported"
    exit 1
}