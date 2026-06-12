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
  kubeconfig_path             = abspath("${path.module}/../../.state/kubeconfig.yaml")
  kube_context                = "kind-fogstack"
  sample_app_chart_path       = abspath("${path.module}/../../examples/sample-app/chart")
  gateway_route_chart_path    = abspath("${path.module}/charts/gateway-route")
  envoy_gateway_chart_version = "v1.5.1"
  fluent_bit_chart_version    = "0.57.7"
  fluent_bit_image_repository = "cr.fluentbit.io/fluent/fluent-bit"
  fluent_bit_image_tag        = "5.0.7"
  aws_cli_image               = "amazon/aws-cli:2.34.20"
  aws_api_endpoint_in_cluster = "http://aws-api.fogstack.svc.cluster.local:4566"
  opensearch_host_in_cluster  = "opensearch.fogstack.svc.cluster.local"
  incluster_bucket_name       = "fogstack-incluster-phase3"
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

resource "kubernetes_namespace_v1" "fogstack" {
  metadata {
    name = "fogstack"
  }
}

resource "kubernetes_namespace_v1" "envoy_gateway_system" {
  metadata {
    name = "envoy-gateway-system"
  }
}

resource "kubernetes_service_v1" "aws_api" {
  metadata {
    name      = "aws-api"
    namespace = kubernetes_namespace_v1.fogstack.metadata[0].name
  }

  spec {
    type          = "ExternalName"
    external_name = "fogstack-emulator"

    port {
      name        = "http"
      port        = 4566
      target_port = 4566
    }
  }
}

resource "kubernetes_service_v1" "opensearch" {
  metadata {
    name      = "opensearch"
    namespace = kubernetes_namespace_v1.fogstack.metadata[0].name
  }

  spec {
    type          = "ExternalName"
    external_name = "fogstack-opensearch"

    port {
      name        = "http"
      port        = 9200
      target_port = 9200
    }
  }
}

resource "helm_release" "sample_app" {
  name      = "sample-app"
  chart     = local.sample_app_chart_path
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

resource "helm_release" "envoy_gateway" {
  name       = "envoy-gateway"
  repository = "oci://docker.io/envoyproxy"
  chart      = "gateway-helm"
  version    = local.envoy_gateway_chart_version
  namespace  = kubernetes_namespace_v1.envoy_gateway_system.metadata[0].name
  wait       = true
  timeout    = 300

  depends_on = [
    kubernetes_namespace_v1.envoy_gateway_system
  ]
}

resource "helm_release" "gateway_route" {
  name      = "fogstack-gateway-route"
  chart     = local.gateway_route_chart_path
  namespace = "default"
  wait      = true
  timeout   = 180

  values = [
    yamlencode({
      gatewayClassName = "fogstack-envoy"
      gatewayName      = "sample-gateway"
      hostnames        = ["sample.fogstack.test"]
      serviceName      = "sample-app"
      servicePort      = 80
    })
  ]

  depends_on = [
    helm_release.envoy_gateway,
    helm_release.sample_app
  ]
}

resource "kubernetes_job_v1" "aws_cli_incluster" {
  metadata {
    name      = "fogstack-aws-cli-incluster"
    namespace = kubernetes_namespace_v1.fogstack.metadata[0].name
  }

  spec {
    backoff_limit = 2

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"       = "fogstack-aws-cli-incluster"
          "app.kubernetes.io/managed-by" = "fogstack"
        }
      }

      spec {
        restart_policy = "Never"

        container {
          name    = "aws-cli"
          image   = local.aws_cli_image
          command = ["sh", "-c"]
          args = [<<-EOT
            set -eu
            aws --endpoint-url "${local.aws_api_endpoint_in_cluster}" s3 mb "s3://${local.incluster_bucket_name}" || true
            aws --endpoint-url "${local.aws_api_endpoint_in_cluster}" s3 ls | grep "${local.incluster_bucket_name}"
          EOT
          ]

          env {
            name  = "AWS_ACCESS_KEY_ID"
            value = "test"
          }

          env {
            name  = "AWS_SECRET_ACCESS_KEY"
            value = "test"
          }

          env {
            name  = "AWS_DEFAULT_REGION"
            value = "us-east-1"
          }

          env {
            name  = "AWS_EC2_METADATA_DISABLED"
            value = "true"
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "5m"
    update = "5m"
  }

  depends_on = [
    kubernetes_service_v1.aws_api
  ]
}

resource "helm_release" "fluent_bit" {
  name       = "fluent-bit"
  repository = "https://fluent.github.io/helm-charts"
  chart      = "fluent-bit"
  version    = local.fluent_bit_chart_version
  namespace  = kubernetes_namespace_v1.fogstack.metadata[0].name
  wait       = true
  timeout    = 300

  values = [
    yamlencode({
      image = {
        repository = local.fluent_bit_image_repository
        tag        = local.fluent_bit_image_tag
      }
      testFramework = {
        enabled = false
      }
      config = {
        outputs = <<-EOT
          [OUTPUT]
              Name opensearch
              Match kube.*
              Host ${local.opensearch_host_in_cluster}
              Port 9200
              Index kind-logs
              Logstash_Format On
              Logstash_Prefix kind-logs
              Suppress_Type_Name On
              Retry_Limit False
        EOT
      }
    })
  ]

  depends_on = [
    kubernetes_service_v1.opensearch
  ]
}

output "sample_app_release" {
  value = helm_release.sample_app.name
}

output "gateway_hostname" {
  value = "sample.fogstack.test"
}

output "aws_api_service" {
  value = local.aws_api_endpoint_in_cluster
}

output "incluster_bucket_name" {
  value = local.incluster_bucket_name
}
