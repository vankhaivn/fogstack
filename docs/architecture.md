# Architecture

This document explains what fogstack is, how the pieces fit together, and — most
importantly — how it stays isolated from the Kubernetes and AWS configuration
already on your machine. Read it when you want to understand the system you are
running, debug unexpected behavior, or decide whether to trust it with a machine
that also holds real credentials.

For commands and lookup tables, see the [Reference](reference.md). For
day-to-day operation, see the [Runbook](runbook.md).

## What fogstack Is

fogstack gives a personal project a set of AWS-shaped local endpoints — a
Kubernetes cluster, an image registry, a Postgres database, and optionally an
AWS-compatible API and OpenSearch — so you can develop and wire integrations
without spending cloud money or touching a real account.

It is built around one non-negotiable rule: **a fogstack command must never read
or write your host's `~/.kube` or `~/.aws`, and must never reach a real AWS
account.** Everything else in the design follows from that rule.

It is a local development tool, not a production-parity environment. See "Limits"
in the [README](../README.md) for what it deliberately does not do.

## The Big Picture

```text
HOST SHELL
  eval "$(engine/fog endpoints)"  ->  KUBECONFIG, REGISTRY, POSTGRES_URL,
                                      AWS_ENDPOINT_URL (full), ...
      |
      v
┌─ Docker engine ───────────────────────────────────┐
│                                                   │
│ default network                                   │
│   postgres      127.0.0.1:5432                    │
│   dashboards    127.0.0.1:5601    (full)          │
│                                                   │
│ "kind" network                                    │
│   control-plane + 2 worker nodes                  │
│   registry      pull via fogstack-registry:5000   │
│   emulator      127.0.0.1:4566    (full)          │
│   opensearch    127.0.0.1:9200    (full)          │
│   load balancer containers (one per Service)      │
│                                                   │
│ all host ports bind to 127.0.0.1 only             │
└───────────────────────────────────────────────────┘
      |
      v
INSIDE THE CLUSTER
  your pods  ->  Service (LoadBalancer)  ->  local LB container  ->  localhost port
  your pods  ->  http://fogstack-emulator:4566    (AWS API, full)
  your pods  ->  http://fogstack-opensearch:9200  (OpenSearch, full)
```

## Components

The `minimal` profile starts the core development loop:

- **kind cluster** — one control-plane node and two worker nodes, running the
  pinned Kubernetes version. The cluster lives entirely in Docker containers on a
  Docker network named `kind`.
- **Local registry** — a `registry` container published at `localhost:5001`. You
  push images here; the cluster nodes pull from it (see "How images reach the
  cluster" below).
- **Postgres** — a database published at `localhost:5432` for host-side
  development.
- **Load balancer controller** — `cloud-provider-kind`, which gives Kubernetes
  `Service` objects of type `LoadBalancer` a working local address.

The `full` profile adds AWS-shaped services:

- **AWS-compatible API** — an emulator published at `localhost:4566`, also
  reachable from inside the cluster as `fogstack-emulator:4566`.
- **OpenSearch** at `localhost:9200` and **OpenSearch Dashboards** at
  `localhost:5601`, useful as a local log or document store.

A complete table of containers, ports, and volumes is in the
[Reference](reference.md).

## Host Isolation — How It Works

This is the heart of the design. Before any fogstack command runs a `kubectl`,
`aws`, `helm`, or `terraform` client, it sources a small guard that redirects
every client away from your host configuration:

- **Kubernetes** — `KUBECONFIG` is exported to `<repo>/.state/kubeconfig.yaml`.
  The cluster is created with that file, and every command reads it. Your host
  kubeconfig and current context are never read and never changed. The setup
  never runs `kubectl config use-context`.
- **AWS configuration files** — `AWS_CONFIG_FILE` and
  `AWS_SHARED_CREDENTIALS_FILE` point at files inside `.state/`, not at
  `~/.aws`.
- **AWS credentials** — fake values (`test` / `test`, region `us-east-1`) are
  exported for the process. The instance-metadata endpoint is disabled.
- **Real-account variables are removed** — `AWS_PROFILE`, `AWS_SESSION_TOKEN`,
  and `AWS_ROLE_ARN` are unset, so a profile lingering in your shell cannot leak
  in. `fog doctor` fails if `AWS_PROFILE` is still set.

Two details make this robust rather than best-effort:

1. **The guard runs at every entry point.** It is not only in the main `fog`
   script — the scripts that create the cluster and start the load balancer
   source it too, so no code path reaches a client with host configuration
   active.
2. **The guard is re-asserted after local settings load.** The `fog` script
   loads your `.env`, then sources the guard again. Even a `.env` that tried to
   set `KUBECONFIG` or an AWS path cannot redirect a client back at your host
   files.

You can confirm the result at any time: `fog doctor` prints the isolation
checks, and `fog endpoints` shows exactly which files are in use. Every service
port also binds to `127.0.0.1` only, so nothing is exposed to your network.

`.state/` is created with restrictive permissions and is safe to delete when the
stack is down; `fog up` regenerates it.

## How A Command Reaches A Local Endpoint

On the host, the flow is always the same:

1. `fog up` starts or reuses the containers for the chosen profile and waits for
   health.
2. `eval "$(fog endpoints)"` exports the connection variables into your shell.
3. Your tools — `kubectl`, `helm`, `psql`, `aws`, the Docker CLI — use those
   variables to reach the local containers. AWS SDKs and the AWS CLI must be
   given the endpoint explicitly (`--endpoint-url "$AWS_ENDPOINT_URL"`); they do
   not discover it automatically.

The variables are per-shell on purpose. Open a new terminal and you re-run
`eval "$(fog endpoints)"` there. They are local development values and should not
be exported globally from your shell profile.

## Networking

A few wiring details explain behavior you will observe.

**How images reach the cluster.** You push to `localhost:5001` from the host.
The registry container is also attached to the `kind` network, and each cluster
node is configured with a containerd registry mirror so that `localhost:5001`
resolves to the registry over the `kind` network. That is why a chart can use an
image like `localhost:5001/my-app:dev` and the nodes can still pull it.

**Reaching the AWS API from inside the cluster.** The emulator is attached to
the `kind` network under the name `fogstack-emulator`, so a pod can call
`http://fogstack-emulator:4566` directly — no host round-trip. The emulator also
launches its own backing containers (for example database proxies) onto the
`kind` network, which is why it is given access to the Docker socket. OpenSearch
is bridged the same way as `fogstack-opensearch:9200`. Postgres and Dashboards
are published to the host only; treat Postgres as a host-side development
database rather than an in-cluster service.

**Load balancer addresses.** `cloud-provider-kind` watches for `Service` objects
of type `LoadBalancer` and starts a small load balancer container for each one.
With local port mapping enabled, it also publishes that service on a `localhost`
port. On Docker Desktop the assigned ingress IP is sometimes not directly
routable from the host, so the published `localhost` port is the reliable way in
— the [Tutorial](tutorial-first-app.md) shows how to find it.

## Profiles And Why They Exist

`minimal` is the default because most development needs only Kubernetes, a
registry, and a database, and that set starts quickly. `full` adds the AWS API,
OpenSearch, and Dashboards, which cost more memory and start time. Splitting them
keeps the common case fast and avoids advertising endpoints that are not running
— for example, `fog endpoints` deliberately omits `AWS_ENDPOINT_URL` in minimal
mode rather than pointing at a dead port.

Switch profiles with `--profile full` on `fog up`; see "Profile Changes" in the
[Runbook](runbook.md).

## State And Lifecycle

Two kinds of state exist:

- **`.state/`** holds the repo-local kubeconfig, the repo-local AWS config files,
  and the last-started profile. It is disposable runtime configuration.
- **Docker named volumes** (`fogstack-pgdata`, `fogstack-emulator-data`,
  `fogstack-opensearch-data`) hold the actual data — database rows, buckets and
  queues, search indices.

`fog down` stops and removes the containers and the cluster but keeps the data
volumes; `fog down --volumes` also removes them. The full picture of what
survives each command, and what to do after a reboot or upgrade, is in the
[FAQ](faq.md).

## What This Enables, And What It Does Not

The design buys you a fast, disposable, AWS-shaped local environment that is safe
to run next to real credentials. It does not give you production parity: the
emulator implements an AWS-compatible surface that varies in depth by service,
IAM is not a real authorization boundary, and network policy is not enforced. Use
it for development feedback and integration wiring — see "Limits" in the
[README](../README.md), and [AWS Recipes](aws-recipes.md) for concrete
workflows.
