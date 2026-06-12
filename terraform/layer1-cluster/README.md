# Layer 1 Cluster

This Terraform layer documents the `tehcyx/kind` provider shape for the fogstack
cluster. Phase 1 keeps `stack/scripts/create-cluster.sh` as the canonical path
because the local registry lifecycle also needs Docker container/network setup
and per-node `hosts.toml` installation from the official kind guide.

Use this layer only as a provider/schema reference until a later ADR promotes it
to the authoritative cluster path.
