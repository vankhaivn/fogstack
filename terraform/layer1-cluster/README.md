# Layer 1 Cluster

This Terraform layer documents the `tehcyx/kind` provider shape for the fogstack
cluster. The shell cluster script remains the canonical path
because the local registry lifecycle also needs Docker container/network setup
and per-node `hosts.toml` installation from the official kind guide.

Use this layer only as a provider/schema reference until the registry lifecycle
can be managed cleanly from Terraform.
