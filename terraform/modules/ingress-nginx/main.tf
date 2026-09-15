locals {
  default_values = {
    controller = {
      replicaCount = var.replica_count

      ingressClassResource = {
        name    = var.ingress_class_name
        enabled = true
        default = true
      }

      ingressClass = var.ingress_class_name

      service = {
        type                  = "LoadBalancer"
        externalTrafficPolicy = "Cluster"
        annotations           = var.service_annotations
      }

      config = {
        # LDES members are posted as RDF payloads which can exceed the 1m nginx default.
        "proxy-body-size" = var.proxy_body_size
      }

      admissionWebhooks = {
        enabled = true
      }
    }
  }
}

resource "helm_release" "this" {
  name             = var.release_name
  namespace        = var.namespace
  create_namespace = true

  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = var.chart_version

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 900

  values = [
    yamlencode(local.default_values),
    yamlencode(var.extra_values),
  ]
}

# The OVHcloud load balancer is provisioned asynchronously; the helm release only waits for the
# controller pods. Reading the service afterwards gives the stack the public address to build
# per-environment hostnames from.
data "kubernetes_service_v1" "controller" {
  metadata {
    name      = "${helm_release.this.name}-controller"
    namespace = var.namespace
  }

  depends_on = [helm_release.this]
}
