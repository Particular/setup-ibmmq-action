param (
    [string]$ContainerName,
    [string]$ConnectionStringName,
    [string]$ImageTag = "latest"
)

$ErrorActionPreference = 'Stop'

# Require setup-wsl-action to have run first — it provisions WSL/Docker and exports
# the WslTools module at WSL_TOOLS_MODULE_PATH.
if (-not $Env:WSL_TOOLS_MODULE_PATH) {
    throw "This action requires Particular/setup-wsl-action to run first — it provisions WSL/Docker and exports the WslTools module at WSL_TOOLS_MODULE_PATH."
}
Import-Module $Env:WSL_TOOLS_MODULE_PATH -Force

function Export-Env {
    param([string]$Name, [string]$Value)
    "$Name=$Value" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
}

$runnerOs = $Env:RUNNER_OS ?? "Linux"

# Generate a password for the admin user. IBM MQ requires a password for the
# admin account; a GUID satisfies the complexity requirements.
$adminPassword = [guid]::NewGuid().ToString()
Write-Output "::add-mask::$adminPassword"

# Validate the image tag — it's user-controlled and interpolated into docker commands.
# Docker tags: max 128 chars, alphanumeric + _ . -, must start with alphanumeric or _.
if ($ImageTag -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$') {
    throw "image-tag must be a valid Docker image tag (alphanumeric, underscore, period, hyphen; max 128 chars). Got: $ImageTag"
}

$queueManagerName = "QM1"
$image = "icr.io/ibm-messaging/mq:$ImageTag"
$port = 1414

if ($runnerOs -eq "Linux") {
    Write-Output "Running IBM MQ in container $ContainerName using Docker"

    docker run --name $ContainerName --detach --restart unless-stopped `
        --publish "${port}:${port}" --publish "9443:9443" `
        --health-cmd "dspmq" --health-interval 10s --health-timeout 5s --health-retries 10 --health-start-period 30s `
        -e LICENSE=accept -e MQ_QMGR_NAME=$queueManagerName -e MQ_ADMIN_PASSWORD=$adminPassword `
        $image

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to start IBM MQ container"
    }

    $ipAddress = "localhost"
}
elseif ($runnerOs -eq "Windows") {
    Write-Output "Running IBM MQ in container $ContainerName using WSL"

    # WSL and Docker were provisioned by setup-wsl-action. Read the distribution
    # and the WSL VM IP from the environment it exported.
    $wslDistribution = $Env:WSL_DISTRIBUTION
    $ipAddress = $Env:WSL_IP

    Write-Output "WSL address: $ipAddress"

    # Use array splatting to avoid WSL interop quoting issues — never pass
    # multi-line commands with backslash continuations through wsl.exe.
    $dockerArgs = @(
        "run", "--name", $ContainerName, "--detach", "--restart", "unless-stopped",
        "--publish", "${port}:${port}", "--publish", "9443:9443",
        "--health-cmd", "dspmq", "--health-interval", "10s", "--health-timeout", "5s",
        "--health-retries", "10", "--health-start-period", "30s",
        "-e", "LICENSE=accept",
        "-e", "MQ_QMGR_NAME=$queueManagerName",
        "-e", "MQ_ADMIN_PASSWORD=$adminPassword",
        $image
    )
    & wsl.exe --distribution $wslDistribution -- docker @dockerArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to start IBM MQ container in WSL"
    }

    & wsl.exe --distribution $wslDistribution -- docker ps --filter "name=$ContainerName"
}
else {
    throw "$runnerOs not supported"
}

# Wait for IBM MQ to be ready. The dspmq command is IBM MQ's built-in queue
# manager status check — it returns 0 when the queue manager is running.
# We poll via docker exec because the host doesn't have IBM MQ client tooling.
Write-Output "::group::Waiting for IBM MQ to be ready"
$ready = $false
for ($i = 1; $i -le 30; $i++) {
    Write-Output "Attempt $i/30 to check IBM MQ readiness..."

    if ($runnerOs -eq "Linux") {
        docker exec $ContainerName dspmq 2>$null
        $ok = $LASTEXITCODE -eq 0
    }
    else {
        $result = Invoke-Wsl -Distribution $wslDistribution -Command "docker exec $ContainerName dspmq 2>/dev/null"
        $ok = $LASTEXITCODE -eq 0
    }

    if ($ok) {
        Write-Output "  - IBM MQ is ready"
        $ready = $true
        break
    }

    Write-Output "  - Not ready, sleeping for 5s"
    Start-Sleep -seconds 5
}
Write-Output "::endgroup::"

if (-not $ready) {
    throw "IBM MQ did not become ready within 150s."
}

# Export the connection string. Uses the admin user with the generated password.
# The channel (DEV.ADMIN.SVRCONN) and topic prefix (DEV) are the IBM MQ default
# developer configuration values.
$connectionString = "mq://admin:${adminPassword}@${ipAddress}:${port}/${queueManagerName}?channel=DEV.ADMIN.SVRCONN&topicprefix=DEV"

Write-Output "Setting environment variable $ConnectionStringName to IBM MQ connection string..."
Export-Env -Name $ConnectionStringName -Value $connectionString