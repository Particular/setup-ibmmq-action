# setup-ibmmq-action

This action handles the setup and teardown of an IBM MQ broker for testing.

## Usage

See [action.yml](action.yml)

```yaml
steps:
  - name: Checkout
    uses: actions/checkout@v7
  - name: Setup WSL
    uses: Particular/setup-wsl-action@v1.1.0
  - name: Setup IBM MQ
    uses: Particular/setup-ibmmq-action@v1.0.0 # Check if this is the latest version at https://github.com/Particular/setup-ibmmq-action/tags
    with:
      connection-string-name: IBMMQ_CONNECTION_STRING
  - name: Run tests
    shell: pwsh
    run: |
      $connstr = $Env:IBMMQ_CONNECTION_STRING
      # Use the connection string in tests...
```

`connection-string-name` is required. `image-tag` is optional (defaults to `9.4.5.1-r1`).

## How it works

On Linux runners the IBM MQ container runs directly through Docker. On Windows runners the Linux IBM MQ container runs inside WSL2 (provisioned by `setup-wsl-action`), so no Azure Container Instances are required.

The action:
1. Starts an IBM MQ container using the `icr.io/ibm-messaging/mq` image with `LICENSE=accept` and a generated admin password.
2. Waits for the queue manager to be ready by polling `dspmq` (IBM MQ's built-in status check) via `docker exec`.
3. Sets the connection string environment variable in the format `mq://admin:<password>@<host>:1414/QM1?channel=DEV.ADMIN.SVRCONN&topicprefix=DEV`.
4. Tears the container down in a post step.

## Prerequisites

This action requires `Particular/setup-wsl-action` to run first. It provisions WSL2 + Docker on Windows runners and exports the `WslTools` PowerShell module and WSL environment variables (`WSL_DISTRIBUTION`, `WSL_IP`, `WSL_TOOLS_MODULE_PATH`) that this action relies on.

## Parameters

| Parameter | Required | Default | Description |
|---|:-:|:-:|---|
| `connection-string-name` | Yes | - | Environment variable name that will be filled with the IBM MQ connection string. |
| `image-tag` | No | `9.4.5.1-r1` | The tag of the IBM MQ container image from `icr.io/ibm-messaging/mq`. |

## Connection string

The generated connection string uses the admin user with a generated password:

```text
mq://admin:<password>@<host>:1414/QM1?channel=DEV.ADMIN.SVRCONN&topicprefix=DEV
```

- On **Linux** the host is `localhost`.
- On **Windows** the host is the WSL2 VM IP address (set by `setup-wsl-action`).
- The channel (`DEV.ADMIN.SVRCONN`) and topic prefix (`DEV`) are the default developer configuration values from the IBM MQ container.

## Least-privilege testing

This action does not set up least-privilege users. If your tests require a non-privileged user, run the least-privilege setup script via `docker exec` after this action. On Windows, Docker runs inside WSL, so the command must go through WSL:

```yaml
- name: Setup least-privilege users
  shell: pwsh
  run: |
    if ($Env:WSL_DISTRIBUTION) {
      wsl.exe --distribution $Env:WSL_DISTRIBUTION -- docker exec ibmmq bash /path/to/setup-leastpriv-tests.sh
    } else {
      docker exec ibmmq bash /path/to/setup-leastpriv-tests.sh
    }
```

The script runs inside the container, so it uses the container's IBM MQ tooling directly (no host-side client needed).

## Cleanup

The action runs a JavaScript-based entry point (`dist/index.mjs`) for both `main` and `post`. The post step invokes `cleanup.ps1`, which removes the IBM MQ container it started. The container name (`ibmmq`) is pinned and persisted via the action state so the post step can target the right container.

On hosted runners this cleanup is harmless — the runner VM is destroyed at the end of the job — but it keeps long-lived self-hosted runners from accumulating orphaned containers.

## Local development

Install dependencies and build the bundle:

```bash
npm install
npm run prepare
```

The `prepare` script runs `@vercel/ncc` to bundle `index.mjs` and its dependencies into `dist/index.mjs`. The committed `dist/` is what the runner executes — the source `index.mjs` is not used directly.

To test `setup.ps1` directly during local debugging:

```bash
$Env:RUNNER_OS=Linux
.\setup.ps1 -ContainerName ibmmq -ConnectionStringName IBMMQ_CONNECTION_STRING
```

## License

MIT