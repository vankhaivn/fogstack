# fogstack Full-Tour Example

This example is a small Go notes service that exercises the full fogstack app
loop from inside Kubernetes:

- Postgres stores note rows.
- Redis caches note payloads.
- S3 stores each note as an object through the AWS-compatible endpoint.
- OpenSearch indexes and searches note text.

Run it on the `full` profile.

## Build And Push

```bash
./engine/fog up --profile full
eval "$(./engine/fog endpoints --profile full)"
FULL_TOUR_IMAGE_TAG="$(awk -F= '$1=="FULL_TOUR_IMAGE_TAG"{print $2}' versions.env)"
GO_BUILDER_IMAGE="$(awk -F= '$1=="GO_BUILDER_IMAGE"{print $2}' versions.env)"

docker build \
  --build-arg "GO_BUILDER_IMAGE=${GO_BUILDER_IMAGE}" \
  -t "$REGISTRY/full-tour:$FULL_TOUR_IMAGE_TAG" \
  examples/full-tour/app
docker push "$REGISTRY/full-tour:$FULL_TOUR_IMAGE_TAG"
```

## Deploy

```bash
helm upgrade --install full-tour examples/full-tour/chart \
  --kubeconfig "$KUBECONFIG" \
  --kube-context "$KUBE_CONTEXT" \
  --namespace fogstack \
  --create-namespace \
  --set "image.repository=$REGISTRY/full-tour" \
  --set "image.tag=$FULL_TOUR_IMAGE_TAG" \
  --wait --timeout 240s
```

## Check It

```bash
FULL_TOUR_IP="$(kubectl --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" \
  -n fogstack get svc full-tour -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

curl "http://$FULL_TOUR_IP/healthz"
curl -sS -X POST "http://$FULL_TOUR_IP/notes" \
  -H 'content-type: application/json' \
  -d '{"title":"fogstack full tour","body":"hello from Postgres, Redis, S3, and OpenSearch"}'
curl "http://$FULL_TOUR_IP/notes"
```

`/healthz` should report `postgres`, `redis`, `s3`, and `opensearch` as OK.

## Terraform Variant

`terraform/` contains an IaC variant for installing the same chart plus the
supporting in-cluster service aliases. It expects the fogstack cluster to
already be running and the full-tour image to exist in the local registry.
