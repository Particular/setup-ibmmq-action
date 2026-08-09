param (
    [string]$ContainerName,
    [string]$ConnectionStringName,
    [string]$ImageTag = "9.4.5.1-r1",
    [string]$InitScript = ""
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

# Wait for IBM MQ to be ready. The dspmq command shows queue manager status —
# but returns exit code 0 even when the status is "Starting", not "Running".
# We must check the actual output for "Running", not just the exit code,
# otherwise runmqsc will fail with "queue manager does not exist" because
# the queue manager isn't accepting connections yet.
Write-Output "::group::Waiting for IBM MQ to be ready"
$ready = $false
for ($i = 1; $i -le 30; $i++) {
    Write-Output "Attempt $i/30 to check IBM MQ readiness..."

    if ($runnerOs -eq "Linux") {
        $dspmqOutput = (docker exec $ContainerName dspmq 2>$null) -join "`n"
        $ok = ($LASTEXITCODE -eq 0) -and ($dspmqOutput -match 'Running')
    }
    else {
        $dspmqOutput = (Invoke-Wsl -Distribution $wslDistribution -Command "docker exec $ContainerName dspmq 2>/dev/null") -join "`n"
        $ok = ($LASTEXITCODE -eq 0) -and ($dspmqOutput -match 'Running')
    }

    if ($ok) {
        Write-Output "  - IBM MQ is ready ($dspmqOutput)"
        $ready = $true
        break
    }

    Write-Output "  - Not ready (status: $dspmqOutput), sleeping for 5s"
    Start-Sleep -seconds 5
}
Write-Output "::endgroup::"

if (-not $ready) {
    throw "IBM MQ did not become ready within 150s."
}

# Create dspmq and runmqsc shims on PATH so consumers and CI can call IBM MQ
# commands the same way on both platforms — Linux (Docker directly) and
# Windows (Docker inside WSL). Mirrors the sqlcmd shim pattern from
# install-sql-server-action.
#
# On Windows the shims route through `bash -c` with each argument quoted:
# wsl.exe re-parses argv as a shell command line, so an unquoted argument with
# parentheses or other shell-special characters would cause a syntax error.
Write-Output "Creating dspmq and runmqsc forwarding scripts"
$shimDir = Join-Path $Env:RUNNER_TEMP "ibmmq-shim"
New-Item -ItemType Directory -Force -Path $shimDir | Out-Null

if ($runnerOs -eq "Linux") {
    # Bash scripts — stdin flows naturally to docker exec -i
    $dspmqPath = Join-Path $shimDir "dspmq"
    Set-Content -Path $dspmqPath -Value "#!/bin/bash`ndocker exec $ContainerName dspmq `"$@`"" -Encoding ASCII
    & chmod +x $dspmqPath

    $runmqscPath = Join-Path $shimDir "runmqsc"
    Set-Content -Path $runmqscPath -Value "#!/bin/bash`ndocker exec -i $ContainerName runmqsc `"$@`"" -Encoding ASCII
    & chmod +x $runmqscPath
}
elseif ($runnerOs -eq "Windows") {
    $dspmqPath = Join-Path $shimDir "dspmq.ps1"
    Set-Content -Path $dspmqPath -Encoding ASCII -Value @"
`$quoted = (`$args | ForEach-Object { "'" + (`$_ -replace "'", "'\''") + "'" }) -join ' '
`$command = "docker exec $ContainerName dspmq `$quoted"
wsl.exe --distribution `$env:WSL_DISTRIBUTION --user root -- bash -c `$command
"@

    $runmqscPath = Join-Path $shimDir "runmqsc.ps1"
    Set-Content -Path $runmqscPath -Encoding ASCII -Value @"
`$quoted = (`$args | ForEach-Object { "'" + (`$_ -replace "'", "'\''") + "'" }) -join ' '
`$command = "docker exec -i $ContainerName runmqsc `$quoted"
`$input | wsl.exe --distribution `$env:WSL_DISTRIBUTION --user root -- bash -c `$command
"@
}

Write-Output "Adding IBM MQ shims to PATH"
$shimDir | Out-File -FilePath $Env:GITHUB_PATH -Encoding utf8 -Append
# GITHUB_PATH only affects subsequent steps; set in current process too.
if ($runnerOs -eq "Linux") {
    $Env:PATH = "$shimDir`:$Env:PATH"
} else {
    $Env:PATH = "$shimDir;$Env:PATH"
}

# Export the connection string. Uses the admin user with the generated password.
# The channel (DEV.ADMIN.SVRCONN) and topic prefix (DEV) are the IBM MQ default
# developer configuration values.
$connectionString = "mq://admin:${adminPassword}@${ipAddress}:${port}/${queueManagerName}?channel=DEV.ADMIN.SVRCONN&topicprefix=DEV"

Write-Output "Setting environment variable $ConnectionStringName to IBM MQ connection string..."
Export-Env -Name $ConnectionStringName -Value $connectionString

if ($InitScript) {
    Write-Output "::group::Running init script $InitScript"

    if (-not (Test-Path -LiteralPath $InitScript)) {
        throw "Init script not found: $InitScript"
    }

    # Copy into the container via docker cp and run with bash — no stdin piping, so no CRLF.
    # Normalize to LF first: scripts may be checked out with CRLF on Windows.
    $script = (Get-Content -LiteralPath $InitScript -Raw) -replace "`r`n", "`n"
    $hostScriptPath = Join-Path $Env:RUNNER_TEMP "init-script.sh"
    [IO.File]::WriteAllText($hostScriptPath, $script)
    $containerScriptPath = "/tmp/init-script.sh"

    if ($runnerOs -eq "Linux") {
        docker cp $hostScriptPath "${ContainerName}:${containerScriptPath}"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to copy init script into the container"
        }
        docker exec -u 0 $ContainerName bash $containerScriptPath
    }
    else {
        # ConvertTo-WslPath maps the Windows path to /mnt/<drive>/ for Docker inside WSL.
        $wslScriptPath = ConvertTo-WslPath -WindowsPath $hostScriptPath
        Invoke-Wsl -Distribution $wslDistribution -CheckExitCode -Command "docker cp '$wslScriptPath' '${ContainerName}:${containerScriptPath}'"
        Invoke-Wsl -Distribution $wslDistribution -CheckExitCode -Command "docker exec -u 0 $ContainerName bash $containerScriptPath"
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Init script $InitScript failed with exit code $LASTEXITCODE"
    }

    Write-Output "::endgroup::"
}