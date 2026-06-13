# Tutorial: Your First App

This tutorial walks from `fog up` to an app you can open with `curl`, using the
sample app shipped in [`examples/sample-app`](../examples/sample-app). It takes
about fifteen minutes on a warm Docker Desktop. Every step uses repo-local
state; nothing touches host Kubernetes or AWS configuration.

You will build an image, push it to the local registry, deploy it with Helm,
and reach it through a local load balancer — the same loop you would use
against a real cluster and registry.

## 1. Start The Stack

From the fogstack repository:

```bash
./engine/fog up
eval "$(./engine/fog endpoints)"
./engine/fog status
```

All rows should report `healthy`. Keep this terminal; the exported variables
(`KUBECONFIG`, `KUBE_CONTEXT`, `REGISTRY`, `POSTGRES_URL`) are used in every
step below.

## 2. Build And Push The Image

The sample app is a one-page nginx site. Build it and push it to the local
registry:

```bash
docker build -t "$REGISTRY/sample-app:0.1.0" examples/sample-app
docker push "$REGISTRY/sample-app:0.1.0"
```

The push goes to `localhost:5001`, the registry container started by `fog up`.
The kind cluster nodes are configured to pull from this registry.

## 3. Deploy With Helm

```bash
helm upgrade --install sample-app examples/sample-app/chart \
  --kubeconfig "$KUBECONFIG" \
  --kube-context "$KUBE_CONTEXT" \
  --set "image.repository=$REGISTRY/sample-app" \
  --set image.tag=0.1.0 \
  --wait --timeout 180s
```

`--wait` returns only when the pod is ready. Check what was created:

```bash
kubectl --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" get pods,svc
```

The `sample-app` service has type `LoadBalancer`. The local load balancer
controller assigns it an address, which can take up to a minute on first
deploy.

## 4. Reach The App

Read the assigned load balancer address:

```bash
LB_IP="$(kubectl --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" \
  get svc sample-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
curl "http://$LB_IP"
```

A healthy response contains `fogstack-sample-ok`.

On Docker Desktop the ingress IP is sometimes not directly routable from the
host. In that case the controller publishes a localhost port instead — find it
and use that:

```bash
docker ps --filter "label=io.x-k8s.cloud-provider-kind.cluster=fogstack" \
  --format '{{.Names}} {{.Ports}}'
```

Take the host port mapped to `80/tcp` and `curl "http://localhost:<port>"`.

## 5. Optional: Talk To Postgres

The stack includes a Postgres instance your app can use during development:

```bash
psql "$POSTGRES_URL" -c 'SELECT version();'
```

If `psql` is not installed on the host, run it inside the container:

```bash
docker exec fogstack-postgres psql -U fogstack -d appdb -c 'SELECT version();'
```

Note: Postgres is reachable from your host shell at `localhost:5432`. Pods
inside the cluster do not get a pre-wired route to it; treat it as a
host-side development database.

## 6. Iterate

Change [`examples/sample-app/index.html`](../examples/sample-app/index.html),
then rebuild, push, and roll the deployment:

```bash
docker build -t "$REGISTRY/sample-app:0.1.1" examples/sample-app
docker push "$REGISTRY/sample-app:0.1.1"
helm upgrade sample-app examples/sample-app/chart \
  --kubeconfig "$KUBECONFIG" --kube-context "$KUBE_CONTEXT" \
  --set "image.repository=$REGISTRY/sample-app" \
  --set image.tag=0.1.1 \
  --wait --timeout 180s
curl "http://$LB_IP"
```

That is the whole inner loop: build, push, upgrade, curl.

## 7. Swap In Your Own App

To deploy your own project instead of the sample:

1. Build your image as `"$REGISTRY/<your-app>:<tag>"` and push it.
2. Point your own chart (or a copy of
   [`examples/sample-app/chart`](../examples/sample-app/chart)) at that
   repository and tag.
3. Keep `service.type: LoadBalancer` if you want a local endpoint, or use
   `ClusterIP` plus `kubectl port-forward` for simpler wiring.

For pointing an app's AWS SDK, Terraform, or Postgres configuration at the
stack, see [Connect Your Project](connect-your-project.md).

## 8. Clean Up

```bash
helm uninstall sample-app --kubeconfig "$KUBECONFIG" --kube-context "$KUBE_CONTEXT"
```

Or stop the whole stack — `./engine/fog down` keeps Postgres data,
`./engine/fog down --volumes` removes it. See the
[FAQ](faq.md) for exactly what survives each command.

## If Something Fails

Work through the [Troubleshooting Playbook](playbook.md). The most common
first-run issues are Docker memory below 8 GB, a busy port, and the load
balancer needing one more minute before assigning an address.
