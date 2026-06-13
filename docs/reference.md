# Reference

Lookup tables for the `fog` CLI, exported endpoint variables, `.env` settings,
and the containers, ports, and volumes the stack owns. For task-oriented
guidance, start with the [Runbook](runbook.md) or the
[Tutorial](tutorial-first-app.md) instead.

## CLI Commands

| Command | What it does |
|---|---|
| `fog up [--profile minimal\|full]` | Runs doctor, creates or reuses the kind cluster and registry, starts compose services for the profile, starts the load balancer controller, waits for health (up to three minutes), then prints endpoints. Idempotent. |
| `fog down [--volumes]` | Stops everything fogstack owns: load balancer containers, compose services, registry, kind cluster, and any `fogstack-*` containers. `--volumes` also removes data volumes and networks. |
| `fog status [--profile minimal\|full]` | Prints one row per component with state and health. Exits non-zero if any row is unhealthy. |
| `fog endpoints [--profile minimal\|full]` | Prints `KEY=value` lines for the profile, ready for `eval`. Read-only. |
| `fog doctor [--profile minimal\|full]` | Checks Docker, memory, required commands, version pins, port ownership, and host isolation. Exits `2` on any `[FAIL]`. Version mismatches are warnings unless `FOGSTACK_DEV=1`. |
| `fog tf-init <dir>` | Writes `fogstack_override.tf` into `<dir>`, pointing the Terraform AWS provider at the local endpoint. |
| `fog version` | Prints the fogstack version. |

`--verbose` on any command enables shell tracing. `fog-toolbox` (same
directory) builds and runs the pinned client-tool container; see "Toolbox" in
the [Runbook](runbook.md).

## Variables Printed By `fog endpoints`

| Variable | Profile | Example value |
|---|---|---|
| `KUBECONFIG` | minimal, full | `<repo>/.state/kubeconfig.yaml` |
| `KUBE_CONTEXT` | minimal, full | `kind-fogstack` |
| `REGISTRY` | minimal, full | `localhost:5001` |
| `POSTGRES_URL` | minimal, full | `postgresql://fogstack:test@localhost:5432/appdb` |
| `REDIS_URL` | minimal, full | `redis://localhost:6379/0` |
| `AWS_ENDPOINT_URL` | full | `http://localhost:4566` |
| `OPENSEARCH_URL` | full | `http://localhost:9200` |
| `DASHBOARDS_URL` | full | `http://localhost:5601` |

## `.env` Settings

Copy `.env.example` to `.env` and edit. Values you export in your shell take
precedence over `.env` for `FOGSTACK_PROFILE`, `FOGSTACK_DEV`, and
`FOGSTACK_DOCTOR_HIDE_COMMANDS`.

| Variable | Default | Purpose |
|---|---|---|
| `FOGSTACK_PROFILE` | `minimal` | Default profile when `--profile` is not given. |
| `FOGSTACK_DEV` | `0` | `1` makes doctor treat version-pin mismatches as failures. For developing fogstack itself. |
| `CLUSTER_NAME` | `fogstack` | kind cluster name. |
| `KUBE_CONTEXT` | `kind-fogstack` | Kubernetes context name in the repo-local kubeconfig. |
| `REGISTRY_NAME` | `fogstack-registry` | Registry container name. |
| `REGISTRY_HOST` / `REGISTRY_PORT` | `localhost` / `5001` | Registry endpoint on the host. |
| `POSTGRES_HOST` / `POSTGRES_PORT` | `localhost` / `5432` | Postgres endpoint on the host. |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | `fogstack` / `test` / `appdb` | Development-only database credentials. |
| `REDIS_HOST` / `REDIS_PORT` / `REDIS_DB` | `localhost` / `6379` / `0` | Redis endpoint on the host. |
| `AWS_ENDPOINT_URL` | `http://localhost:4566` | AWS-compatible endpoint (full profile). |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | `test` / `test` | Fake local credentials. |
| `AWS_DEFAULT_REGION` | `us-east-1` | Fake local region. |
| `OPENSEARCH_URL` / `DASHBOARDS_URL` | `:9200` / `:5601` | OpenSearch endpoints (full profile). |
| `FOGSTACK_CPK_PID_FILE` / `FOGSTACK_CPK_LOG_FILE` | `/tmp/fogstack-cpk.*` | Load balancer controller pid and log files. |
| `FOGSTACK_DOCTOR_HIDE_COMMANDS` | empty | Test hook; leave empty. |

Component image versions and tool pins live in `versions.env`, not `.env`;
see "Version Bumps" in the [Runbook](runbook.md) before changing them.

## Containers, Ports, And Volumes

| Container | Host port | Profile | Role |
|---|---|---|---|
| `fogstack-control-plane`, `fogstack-worker*` | — | minimal, full | kind cluster nodes |
| `fogstack-registry` | `127.0.0.1:5001` | minimal, full | image registry |
| `fogstack-postgres` | `127.0.0.1:5432` | minimal, full | Postgres |
| `fogstack-redis` | `127.0.0.1:6379` | minimal, full | Redis |
| `fogstack-emulator` | `127.0.0.1:4566`, `7001-7099` | full | AWS-compatible API |
| `fogstack-opensearch` | `127.0.0.1:9200` | full | OpenSearch |
| `fogstack-dashboards` | `127.0.0.1:5601` | full | OpenSearch Dashboards |
| cloud-provider-kind LB containers | dynamic | minimal, full | per-service local load balancers |

All ports bind to `127.0.0.1` only. Data volumes: `fogstack-pgdata`,
`fogstack-redis-data`, `fogstack-emulator-data`, `fogstack-opensearch-data` —
kept by `fog down`, removed by `fog down --volumes`.

## Files In `.state/`

| File | Purpose |
|---|---|
| `kubeconfig.yaml` | Repo-local kubeconfig; the only one fog commands use. |
| `aws-config`, `aws-credentials` | Repo-local AWS config files with fake values. |
| `profile` | Profile of the last `fog up`, informational. |

Safe to delete when the stack is down; `fog up` regenerates everything.

## AWS Endpoint Coverage

The emulator behind `:4566` exposes an AWS-compatible API surface. The
Terraform override from `fog tf-init` wires S3, SQS, IAM, STS, RDS, and EKS;
the AWS CLI and SDKs can call any service the emulator implements by passing
`--endpoint-url` / an endpoint override. Working recipes for S3, SQS, IAM,
and Lambda are in [AWS Recipes](aws-recipes.md).

Coverage depth varies by service and moves with emulator releases. Treat
create/read/update/delete wiring as the supported use case, and security or
networking enforcement as out of scope — see "Limits" in the
[README](../README.md).
