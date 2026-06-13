# Connect Your Project

This guide shows how to point an outside project at fogstack without copying
credentials or modifying host cloud configuration.

## Start From A Clean Shell

In the fogstack repository:

```bash
./engine/fog up
eval "$(./engine/fog endpoints)"
```

Keep this terminal open or copy the exported values into the command that starts
your local app. The values are local-only and safe to regenerate.

## Terraform

Generate an AWS provider override in a scratch Terraform directory:

```bash
./engine/fog tf-init ../my-app/terraform
```

The generated override points the AWS provider at fogstack's local AWS endpoint.
Review the file before committing anything in your own project; many teams keep
local override files ignored.

For Kubernetes resources, configure providers with:

```hcl
provider "kubernetes" {
  config_path    = "<fogstack repo>/.state/kubeconfig.yaml"
  config_context = "kind-fogstack"
}
```

## AWS CLI

Use explicit endpoints:

```bash
aws --endpoint-url "$AWS_ENDPOINT_URL" s3 ls
aws --endpoint-url "$AWS_ENDPOINT_URL" sqs list-queues
```

Do not rely on default AWS profiles. fogstack sets fake local credentials for the
process and points AWS config files at `.state/`.

## AWS SDKs

Set the SDK endpoint URL to `AWS_ENDPOINT_URL` and use fake local credentials.
For example, a Node.js app can read:

```bash
AWS_ENDPOINT_URL=http://localhost:4566
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
AWS_REGION=us-east-1
```

Keep service clients explicit. If a service client cannot accept an endpoint
override, do not point it at real AWS credentials during local tests.

## Kubernetes

Use the repo-local kubeconfig:

```bash
kubectl --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" get namespaces
```

Do the same for Helm:

```bash
helm --kubeconfig "$KUBECONFIG" --kube-context "$KUBE_CONTEXT" list -A
```

Application manifests can use normal Kubernetes service discovery once deployed
inside the cluster. For fogstack backing services, pods can reach Postgres at
`fogstack-postgres:5432` and Redis at `fogstack-redis:6379`.

## Postgres

The exported `POSTGRES_URL` is ready for local apps:

```bash
psql "$POSTGRES_URL"
```

In application config, use the host and port from the URL. The default database,
user, and password are development-only values from `.env.example`.

## Redis

The exported `REDIS_URL` is ready for local apps:

```bash
redis-cli -u "$REDIS_URL" ping
```

If `redis-cli` is not installed on the host, use the container:

```bash
docker exec fogstack-redis redis-cli ping
```

In-cluster apps can use `redis://fogstack-redis:6379/0`.

## Registry

Tag images with the exported registry:

```bash
docker build -t "$REGISTRY/my-app:dev" .
docker push "$REGISTRY/my-app:dev"
```

In Helm values, use repository `$REGISTRY/my-app` and tag `dev`. The kind nodes
are configured to pull from this local registry.

## Full Mode Services

Start full mode when you need AWS-compatible APIs, OpenSearch, or Dashboards:

```bash
./engine/fog up --profile full
eval "$(./engine/fog endpoints --profile full)"
```

Use `AWS_ENDPOINT_URL`, `OPENSEARCH_URL`, and `DASHBOARDS_URL` from that command.
Minimal mode intentionally omits those variables so dead endpoints are not
advertised.

## Cleanup

When your project is done testing:

```bash
./engine/fog down
```

Use `./engine/fog down --volumes` when local database state can be removed.
