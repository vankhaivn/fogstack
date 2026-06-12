terraform {
  required_version = ">= 1.14.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 3.2.0"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "= 3.2.0"
    }
  }
}

locals {
  kubeconfig_path = abspath("${path.module}/../../.state/kubeconfig.yaml")
  kube_context    = "kind-fogstack"
  chart_path      = abspath("${path.module}/../../examples/sample-app/chart")
}

provider "kubernetes" {
  config_path    = local.kubeconfig_path
  config_context = local.kube_context
}

provider "helm" {
  kubernetes = {
    config_path    = local.kubeconfig_path
    config_context = local.kube_context
  }
}

resource "helm_release" "sample_app" {
  name      = "sample-app"
  chart     = local.chart_path
  namespace = "default"
  wait      = true
  timeout   = 180

  values = [
    yamlencode({
      image = {
        repository = "localhost:5001/sample-app"
        tag        = "0.1.0"
      }
    })
  ]
}

output "sample_app_release" {
  value = helm_release.sample_app.name
}
