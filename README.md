# fogstack

> **Fog**: the cloud, at ground level. ☁️→💻
>
> An AWS-compatible local cloud stack — EKS, RDS, ECR, S3, SQS and friends running on your laptop, for **$0**. Point your Terraform, Helm, and SDKs at `localhost` and build like you're on AWS, without the bill.

> [!WARNING]
> 🚧 **Status: under active development — not usable yet.**
> The architecture is settled and construction is in progress (see [Roadmap status](#roadmap-status)). Nothing below works until the corresponding phase lands. Star/watch the repo if you want to follow along.

## What you get

One command (`fog up`) exposes a local AWS-shaped platform:

| Endpoint                | Acts as                                     | Backed by                                                                                                         | Status     |
| ----------------------- | ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | ---------- |
| `http://localhost:4566` | AWS API (S3, SQS, IAM, Lambda, ...)         | [Floci](https://github.com/floci-io/floci) (MIT) — pinned, chosen via head-to-head eval                                                 | ⏳ pending |
| dedicated kubeconfig    | EKS — real Kubernetes, `helm install` works | [kind](https://kind.sigs.k8s.io/) + [cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind) | ⏳ pending |
| `localhost:5001`        | ECR — real `docker push`/`pull`             | registry:2                                                                                                        | ⏳ pending |
| `localhost:5432`        | RDS — real PostgreSQL                       | postgres:16                                                                                                       | ⏳ pending |
| `localhost:9200`        | OpenSearch / "ELK"                          | OpenSearch 3.x (`full` profile)                                                                                   | ⏳ pending |

Your projects connect like they would to real AWS: `AWS_ENDPOINT_URL` for SDKs, generated provider override for Terraform, plain kubeconfig for kubectl/Helm.

## Why

Learning AWS infrastructure (Terraform + EKS + RDS + observability) on a real account is expensive and slow to iterate on. Free tiers don't cover EKS control planes or NAT gateways, and one forgotten cluster ruins your month. fogstack assembles proven open-source pieces into one orchestrated, disposable, laptop-sized stack:

- **Real where it matters** — the Kubernetes cluster, database, registry, and search engine are the real thing, not mocks. Helm charts and `kubectl` workflows transfer 1:1 to EKS.
- **AWS-shaped where it helps** — the emulator speaks the AWS wire protocol on port 4566, so `aws` CLI, SDKs, and the Terraform AWS provider work unmodified.
- **Disposable** — everything runs in containers with a `fogstack-` prefix. `fog down --volumes` removes every trace.
- **Isolated by design** — fogstack never touches your `~/.kube/config` or `~/.aws/*`. It uses its own kubeconfig and fake credentials in a repo-local `.state/` directory, so existing work/company contexts stay untouched.

## Quickstart — ⏳ pending (target UX)

This is the experience we are building toward (lands with the CLI phase):

```bash
git clone https://github.com/<you>/fogstack && cd fogstack
cp .env.example .env
./engine/fog up                      # minimal profile: k8s + registry + postgres
eval "$(./engine/fog endpoints)"

aws --endpoint-url "$AWS_ENDPOINT_URL" s3 mb s3://hello   # AWS API, locally
kubectl get nodes                                          # your local "EKS"
```

**Requirements:** macOS (Apple Silicon tested), Docker Desktop with ~8 GB allocated. ~16 GB machine RAM recommended.

## Profiles

| Profile   | Components                                                     | ~RAM (containers) | Status     |
| --------- | -------------------------------------------------------------- | ----------------- | ---------- |
| `minimal` | kind (3 nodes) + registry + postgres                           | ~1.5–2 GB         | ⏳ pending |
| `full`    | minimal + AWS emulator + OpenSearch + Dashboards + Gateway API | ~3.5–5 GB         | ⏳ pending |

## Use it with your project — ⏳ pending

- **Terraform**: `fog tf-init <dir>` generates a provider override pointing every AWS service endpoint at `localhost:4566`. Same `.tf` code, local or real cloud.
- **Any AWS SDK / CLI**: set `AWS_ENDPOINT_URL=http://localhost:4566` (credentials `test`/`test`).
- **Helm / kubectl**: use the kubeconfig from `fog endpoints` — it's a normal multi-node Kubernetes cluster with working `LoadBalancer` services and Gateway API.
- **psql / your app**: standard PostgreSQL connection string from `fog endpoints`.

## Honest limitations

fogstack is a **learning and local-dev tool**, not a production-parity test environment:

- **VPC / Security Groups are API-only.** No local emulator (including paid ones) enforces network semantics — you can `terraform apply` a VPC and learn the workflow, but packets don't obey route tables. For real VPC behavior, use a real (free-component) VPC on AWS.
- **IAM is not actually evaluated.** Roles and policies exist as API objects; nothing enforces them.
- The AWS emulator layer is young (the post-LocalStack-archival generation, 2026). Expect rough edges; we pin exact versions.
- Not a load-testing or performance environment.

## Architecture

```
                       ┌──────────────  fog CLI  ──────────────┐
                       │   up · down · status · endpoints      │
                       └──┬─────────────--─┬──────────────┬────┘
        AWS-shaped APIs   │   real compute │              │ observability (full)
   ┌──────────────────────▼──┐  ┌──────────▼───────────┐  ┌─▼──────────────────┐
   │ emulator :4566          │  │ kind ("EKS")         │  │ OpenSearch :9200   │
   │ S3·SQS·IAM·Lambda·...   │  │ + cloud-provider-kind│  │ + Dashboards :5601 │
   └─────────────────────────┘  │ + Gateway API        │  └────────────────────┘
   ┌─────────────────────────┐  │ registry :5001 (ECR) │
   │ postgres :5432 ("RDS")  │  └──────────────────────┘
   └─────────────────────────┘
        all containers · prefix fogstack- · Docker Desktop VM (~8 GB)
```

Terraform follows the production EKS pattern: **layer 1** provisions the cluster, **layer 2** (`kubernetes` + `helm` providers) manages everything in-cluster — layer 2 code is copy-paste portable to a real EKS cluster.

## Roadmap status

| Phase | Scope                                                     | Status       |
| ----- | --------------------------------------------------------- | ------------ |
| 0     | Evaluate & pin the AWS emulator (Floci vs MiniStack)      | ✅ done — Floci won 99/83 |
| 1     | Minimal stack: kind + registry + postgres + Terraform e2e | ✅ done      |
| 2     | `fog` CLI (up/down/status/endpoints/doctor)               | 🔜 next up   |
| 3     | Full profile: emulator + Gateway API + OpenSearch         | ⏳ pending   |
| 4     | Docs (runbook/playbook), toolbox image, CI                | ⏳ pending   |
| 5     | VPC lab with real network enforcement                     | 💭 exploring |

Docs for end users (runbook, troubleshooting playbook, connect-your-project guide) will live in [`docs/`](docs/) — ⏳ pending, written in Phase 4.

## License & credits

MIT (license file lands with Phase 4).

Standing on the shoulders of: [kind](https://kind.sigs.k8s.io/) · [cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind) · [Floci](https://github.com/floci-io/floci) / [MiniStack](https://github.com/ministackorg/ministack) · [Envoy Gateway](https://gateway.envoyproxy.io/) · [OpenSearch](https://opensearch.org/) · [PostgreSQL](https://www.postgresql.org/) · [Terraform](https://www.terraform.io/) · [Helm](https://helm.sh/)
