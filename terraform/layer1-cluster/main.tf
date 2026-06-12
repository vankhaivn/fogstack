terraform {
  required_version = ">= 1.14.0"

  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "= 0.11.0"
    }
  }
}

locals {
  kubeconfig_path = abspath("${path.module}/../../.state/kubeconfig.yaml")
  node_image      = "kindest/node:v1.35.0@sha256:452d707d4862f52530247495d180205e029056831160e22870e37e3f6c1ac31f"
}

resource "kind_cluster" "fogstack" {
  name            = "fogstack"
  wait_for_ready  = true
  kubeconfig_path = local.kubeconfig_path

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role  = "control-plane"
      image = local.node_image
    }

    node {
      role  = "worker"
      image = local.node_image
    }

    node {
      role  = "worker"
      image = local.node_image
    }

    containerd_config_patches = [
      <<-TOML
      [plugins."io.containerd.grpc.v1.cri".registry]
        config_path = "/etc/containerd/certs.d"
      TOML
    ]
  }
}

output "kubeconfig_path" {
  value = local.kubeconfig_path
}

output "endpoint" {
  value = kind_cluster.fogstack.endpoint
}
