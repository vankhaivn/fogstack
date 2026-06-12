# Runbook

This runbook covers everyday fogstack operation from a clean shell. Commands are
written for macOS with Docker Desktop and repo-local state.

## Start

1. Check Docker Desktop is running.
2. Confirm Docker Desktop has at least 8 GB of memory.
3. Run `./engine/fog doctor`.
4. Start the default stack with `./engine/fog up`.
5. Export endpoints with `eval "$(./engine/fog endpoints)"`.
6. Check health with `./engine/fog status`.

Use `./engine/fog up --profile full` only when you need the AWS-compatible API,
OpenSearch, Dashboards, or Gateway API proof resources.

## Stop

Use `./engine/fog down` when you want containers stopped but local volumes kept.
Use `./engine/fog down --volumes` when you want a clean rebuild and do not need
Postgres data.

After a full cleanup, `docker ps -a` should not show fogstack containers and
`kind get clusters` should not list `fogstack`.

## Status

Run `./engine/fog status` for the default profile. Run
`./engine/fog status --profile full` after starting full mode. Healthy rows
should show `healthy` in the final column.

If a row is unhealthy, prefer `./engine/fog down --volumes` followed by a fresh
`./engine/fog up` before changing configuration.

## Endpoints

Run `eval "$(./engine/fog endpoints)"` before using `kubectl`, `helm`, `psql`, or
registry commands. For full mode, use `eval "$(./engine/fog endpoints --profile
full)"` so AWS and OpenSearch variables are included.

Keep those variables local to a terminal session. They are local development
values and should not be exported globally in your shell profile.

## Profile Changes

To move from minimal to full, run:

```bash
./engine/fog up --profile full
eval "$(./engine/fog endpoints --profile full)"
```

To return to minimal cleanly, run:

```bash
./engine/fog down --volumes
./engine/fog up
```

## Toolbox

Build the pinned toolbox with `./engine/fog-toolbox --build`. Use it for client
commands such as `terraform version`, `kubectl version --client`, `aws --version`,
`psql --version`, `shellcheck`, and `hadolint`.

The toolbox mounts the repository and Docker socket. It does not mount host
Kubernetes or AWS directories. Treat Docker socket access as local-dev trust:
anything with that socket can control Docker on the machine.

## Version Bumps

Change pins in `versions.env` first. Then rebuild the toolbox, run static checks,
and run `checks/smoke.sh`. For Kubernetes node image bumps, keep `kubectl` within
the supported skew of the cluster version.

## Postgres Backup

Create a local dump:

```bash
eval "$(./engine/fog endpoints)"
docker exec fogstack-postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" > fogstack-postgres.sql
```

Restore into a running stack:

```bash
eval "$(./engine/fog endpoints)"
cat fogstack-postgres.sql | docker exec -i fogstack-postgres psql -U "$POSTGRES_USER" "$POSTGRES_DB"
```

## Clean Reset

Use this when you want to remove all local runtime state:

```bash
./engine/fog down --volumes
rm -rf .state
docker rm -f fogstack-cloud-provider-kind 2>/dev/null || true
```
