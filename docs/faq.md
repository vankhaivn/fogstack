# FAQ: Lifecycle, Data, And Environment

Answers to the questions that come up after the first day of use: what
survives a stop, what to do after a reboot, how to upgrade, and what fogstack
does and does not touch on your machine.

## What survives `fog down`?

Data stored in named Docker volumes survives:

- Postgres data (`fogstack-pgdata`)
- AWS emulator state — buckets, queues, functions (`fogstack-emulator-data`)
- OpenSearch indices (`fogstack-opensearch-data`)

Everything else is removed: the kind cluster (including anything you deployed
into Kubernetes), the registry container and the images pushed to it, and the
load balancer containers. After the next `fog up`, redeploy your apps and
re-push images; your database rows, buckets, and indices are still there.

## What does `fog down --volumes` add?

It also deletes the three data volumes above and fogstack-owned Docker
networks. Use it when you want a guaranteed-clean rebuild and do not need the
data. Back up first if in doubt — see "Postgres Backup" in the
[Runbook](runbook.md).

## I rebooted my machine. Now what?

Run the normal start again:

```bash
./engine/fog up
eval "$(./engine/fog endpoints)"
```

`fog up` is idempotent: it reuses whatever came back after the reboot,
restarts what did not, and waits for health. Data volumes are untouched by a
reboot. Apps you deployed into the cluster are still there if the cluster
survived the restart; if the cluster had to be recreated, redeploy them.

## How do I upgrade fogstack?

```bash
git pull
./engine/fog down
./engine/fog up
```

If you use the pinned toolbox, rebuild it after pulling
(`./engine/fog-toolbox --build`). Optionally run `checks/smoke.sh` as a
self-test. If the update bumps the Postgres image to a new major version,
dump your database before upgrading and restore after — minor bumps reuse the
existing volume without ceremony.

## Which platforms are supported?

fogstack is developed and tested on macOS with Docker Desktop. The scripts are
plain Bash over `docker`, `kind`, `kubectl`, `helm`, and `terraform`, so Linux
generally behaves, but it is not part of regular testing. All service ports
bind to `127.0.0.1` only — nothing is exposed to your network.

## Will fogstack touch my real kubeconfig or AWS credentials?

No. Every `fog` command points `KUBECONFIG` at
`<repo>/.state/kubeconfig.yaml`, points AWS config and credentials files at
`.state/`, exports fake local credentials for the process, and refuses to run
with `AWS_PROFILE` set. `~/.kube` and `~/.aws` are never read or written. You
can verify at any time: `./engine/fog doctor` prints the isolation checks, and
`./engine/fog endpoints` shows exactly which files are in use.

## Where does fogstack keep state on disk?

Two places:

- `<repo>/.state/` — the kubeconfig, repo-local AWS config files, and the
  last-started profile. Safe to delete when the stack is down; `fog up`
  regenerates it.
- Docker named volumes (`fogstack-pgdata`, `fogstack-emulator-data`,
  `fogstack-opensearch-data`) — the actual data.

## I opened a new terminal and commands fail. Why?

The endpoint variables are per-shell. Run this in every new terminal:

```bash
eval "$(./engine/fog endpoints)"          # add --profile full in full mode
```

Do not export them globally from your shell profile; they are local
development values that should stay scoped to the sessions using them.

## Why doesn't minimal mode print `AWS_ENDPOINT_URL`?

Minimal mode does not start the AWS emulator, so the variable is intentionally
omitted rather than advertising a dead endpoint. Start full mode and export
full endpoints when you need it.

## Can I run two stacks side by side?

Not on one machine with default settings: the cluster name and all host ports
are fixed. Run one stack at a time, and use `fog down` between projects if
they need different data.

## Can I use the data for anything real?

No. Credentials are fake, security plugins are off, and IAM is not enforced.
fogstack is for development feedback and integration wiring — see "Limits" in
the [README](../README.md).
