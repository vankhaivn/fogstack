# Troubleshooting Playbook

Use this playbook when a command fails or the stack looks stuck. Start with
`./engine/fog doctor`; it separates required failures from warnings that are only
strict for repository development.

## Docker Is Not Reachable

Open Docker Desktop and wait until `docker info` succeeds. If Docker Desktop was
just upgraded, restart it once. Re-run `./engine/fog doctor` before starting the
stack again.

## Docker Memory Is Too Low

Set Docker Desktop memory to at least 8 GB. Full mode is more comfortable with
extra headroom. After changing the setting, restart Docker Desktop and run
`./engine/fog doctor`.

## Required Command Missing

Install the missing host command or use the pinned toolbox for client-only work.
The main stack commands currently expect host `kind`, `kubectl`, `helm`,
`terraform`, `docker`, and `curl`.

## Port Is Busy

Run `./engine/fog doctor`. If the owner is a fogstack container, the stack can
continue. If another app owns the port, stop that app or change the local port in
`.env` before running `./engine/fog up`.

Common ports are `5001` for the registry, `5432` for Postgres, `4566` for the
AWS-compatible API, `9200` for OpenSearch, and `5601` for Dashboards.

## Cluster Does Not Become Ready

Run:

```bash
./engine/fog down --volumes
./engine/fog up
```

If it still fails, inspect Docker and kind state:

```bash
docker ps -a
kind get clusters
```

Delete only fogstack-owned resources. Do not change the host's default Kubernetes
context.

## Registry Push Fails

Re-evaluate endpoints with `eval "$(./engine/fog endpoints)"`. Confirm the image
tag begins with `$REGISTRY/`. Then check the registry:

```bash
curl -fsS "http://$REGISTRY/v2/"
```

If the registry is missing, run `./engine/fog down --volumes` and start again.

## Sample App Has No External Address

The load balancer controller may need a little time. Check:

```bash
docker logs fogstack-cloud-provider-kind
kubectl --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" get svc sample-app -o wide
```

On Docker Desktop, the app may also be reachable through a published localhost
port on a controller-owned container.

## Postgres Is Unhealthy

Check the container logs:

```bash
docker logs fogstack-postgres
```

If the database volume is disposable, run `./engine/fog down --volumes` and start
again. If you need the data, back it up before removing volumes.

## Full Mode AWS Endpoint Is Missing

Minimal mode does not print `AWS_ENDPOINT_URL`. Start full mode and evaluate full
endpoints:

```bash
./engine/fog up --profile full
eval "$(./engine/fog endpoints --profile full)"
aws --endpoint-url "$AWS_ENDPOINT_URL" s3 ls
```

## OpenSearch Is Not Ready

OpenSearch can take longer than the rest of the stack. Check:

```bash
docker logs fogstack-opensearch
curl -fsS "$OPENSEARCH_URL/_cluster/health"
```

If it repeatedly fails after cleanup, increase Docker Desktop memory and retry.

## Host Credentials Look Suspicious

fogstack commands export repo-local AWS config files and a repo-local kubeconfig.
Run `./engine/fog endpoints` and verify `KUBECONFIG` points inside `.state/`.
Never run `kubectl config use-context` as part of fogstack setup.
