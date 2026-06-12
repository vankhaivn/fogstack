# fogstack

fogstack is a local AWS endpoint platform for personal projects. It starts a
repo-local Kubernetes cluster, registry, Postgres database, and optional
AWS-compatible services so an application can be pointed at local endpoints
without touching company kube contexts or real AWS credentials.

## Endpoint Contract

| Endpoint | Profile | Role | Backend |
|---|---|---|---|
| `KUBECONFIG=<repo>/.state/kubeconfig.yaml` | minimal, full | EKS-like Kubernetes target | kind + cloud-provider-kind |
| `localhost:5001` | minimal, full | ECR-like image registry | registry |
| `localhost:5432` | minimal, full | RDS-like Postgres | postgres |
| `http://localhost:4566` | full | AWS API surface for S3, SQS, IAM, Lambda, and related services | Floci |
| `http://localhost:9200` | full | OpenSearch API | OpenSearch |
| `http://localhost:5601` | full | OpenSearch Dashboards | OpenSearch Dashboards |

Every command guards the host first: Kubernetes writes to `.state/kubeconfig.yaml`,
AWS config files point at `.state/`, and fake local credentials are exported for
the process. The stack never needs `~/.kube` or `~/.aws`.

## Quickstart

Prerequisites: Docker Desktop with at least 8 GB assigned to the Docker VM, plus
host binaries for `kind`, `kubectl`, `helm`, `terraform`, and `curl`. The toolbox
image provides pinned client tools for repeatable checks, but the main stack
commands currently run on the host.

```bash
git clone <repo-url> fogstack
cd fogstack
cp .env.example .env
./engine/fog doctor
./engine/fog up
eval "$(./engine/fog endpoints)"
kubectl --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" get nodes
./engine/fog status
```

Optional self-test:

```bash
checks/smoke.sh
```

For an AWS API demo, use the full profile:

```bash
./engine/fog up --profile full
eval "$(./engine/fog endpoints --profile full)"
aws --endpoint-url "$AWS_ENDPOINT_URL" s3 ls
```

## Profiles

| Profile | Starts | Suggested Docker VM memory | Use it when |
|---|---|---:|---|
| `minimal` | kind, local registry, Postgres, sample app plumbing | 8 GB | You need Kubernetes, images, and Postgres quickly. |
| `full` | everything in `minimal`, plus Floci, OpenSearch, Dashboards, Gateway API routing, and log shipping | 8 GB minimum, more is smoother | You need AWS-compatible APIs or observability. |

`fog up` defaults to `minimal`. Use `--profile full` only when your project needs
the AWS-compatible endpoint or OpenSearch.

## Use With Your Project

Run this in your shell after the stack is healthy:

```bash
eval "$(./engine/fog endpoints)"
```

Terraform: generate a local provider override for a scratch directory:

```bash
./engine/fog tf-init path/to/terraform
```

SDKs and AWS CLI: always pass the endpoint explicitly. Example:

```bash
aws --endpoint-url "$AWS_ENDPOINT_URL" s3 ls
```

Kubernetes and Helm: use the repo-local kubeconfig and context:

```bash
kubectl --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" get pods -A
helm --kubeconfig "$KUBECONFIG" --kube-context "$KUBE_CONTEXT" list -A
```

Postgres:

```bash
psql "$POSTGRES_URL"
```

Registry:

```bash
docker build -t "$REGISTRY/my-app:dev" .
docker push "$REGISTRY/my-app:dev"
```

Pinned toolbox:

```bash
./engine/fog-toolbox --build
./engine/fog-toolbox terraform version
```

## Limits

VPC and security-group APIs are useful for create/read/update/delete workflows,
but they do not enforce real network policy. IAM accepts local development flows,
but it is not a real authorization boundary. The AWS-compatible emulator is young
software and can change faster than AWS itself.

Do not use fogstack as a production-parity test environment. It is for local
development feedback, integration wiring, and learning the shape of AWS-adjacent
workflows before spending cloud money.

## Architecture

```text
host shell
  |
  | eval "$(engine/fog endpoints)"
  v
.state/kubeconfig.yaml       localhost:5001        localhost:5432
      |                            |                    |
      v                            v                    v
   kind cluster  <-------- local registry -------->  Postgres
      |
      +-- sample app, Gateway API, cloud-provider-kind
      |
      +-- full profile service aliases
              |                  |
              v                  v
        Floci AWS API       OpenSearch
```

`engine/fog down --volumes` removes stack containers, the kind cluster, local
volumes, and fogstack-owned load balancer containers.

## Troubleshooting

Port already in use: run `./engine/fog doctor`. If a fogstack container owns the
port, startup can continue; if another process owns it, stop that process or
change the relevant port in `.env`.

Docker memory too small: increase Docker Desktop memory to at least 8 GB and
rerun `./engine/fog doctor`.

Cluster not ready: run `./engine/fog down --volumes`, then `./engine/fog up`
again. If it still fails, check `docker ps` and `kind get clusters`.

No load balancer endpoint: wait one more minute, then inspect the cloud provider
container with `docker logs fogstack-cloud-provider-kind`.

Full profile endpoint missing: confirm you started with `./engine/fog up
--profile full` and evaluated `./engine/fog endpoints --profile full`.

Uninstall:

```bash
./engine/fog down --volumes
rm -rf .state
docker image rm "fogstack-toolbox:$(awk -F= '$1==\"FOGSTACK_VERSION\"{print $2}' versions.env)" 2>/dev/null || true
```

## License And Credits

fogstack is released under the MIT License. See [LICENSE](LICENSE).

Credits: Floci for the AWS-compatible API backend, kind for local Kubernetes,
cloud-provider-kind for local load balancer behavior, Envoy Gateway for Gateway
API routing, OpenSearch for local search/log inspection, PostgreSQL, Terraform,
Helm, kubectl, Docker, ShellCheck, and Hadolint.
