locals {
  stream_prefix = "${local.ldes_server_public_url}/${var.event_stream_name}/"

  default_event_stream_configuration = <<-TTL
    @prefix ldes:    <https://w3id.org/ldes#> .
    @prefix dcterms: <http://purl.org/dc/terms/> .
    @prefix tree:    <https://w3id.org/tree#> .
    @prefix sh:      <http://www.w3.org/ns/shacl#> .
    @prefix server:  <${local.ldes_server_public_url}/> .
    @prefix stream:  <${local.stream_prefix}> .

    server:${var.event_stream_name} a ldes:EventStream ;
        ldes:timestampPath dcterms:created ;
        ldes:versionOfPath dcterms:isVersionOf ;
        ldes:createVersions false ;
        tree:shape stream:shape .

    stream:shape a sh:NodeShape .
  TTL

  default_view_configuration = <<-TTL
    @prefix tree: <https://w3id.org/tree#> .
    @prefix xsd:  <http://www.w3.org/2001/XMLSchema#> .

    </${var.event_stream_name}/${var.view_name}> a tree:Node ;
        tree:viewDescription [
            a tree:ViewDescription ;
            tree:fragmentationStrategy () ;
            tree:pageSize "${var.view_page_size}"^^xsd:integer
        ] .
  TTL

  default_streams = [
    {
      name          = var.event_stream_name
      configuration = local.default_event_stream_configuration

      views = [
        {
          name          = var.view_name
          configuration = local.default_view_configuration
        },
      ]
    },
  ]

  streams = var.ldes_server_streams != null ? var.ldes_server_streams : local.default_streams

  ldes_server_values = {
    replicaCount = var.ldes_server_replicas

    fullnameOverride = var.ldes_server_release_name

    image = {
      repository = var.ldes_server_image.repository
      tag        = var.ldes_server_image.tag
      pullPolicy = var.ldes_server_image.pull_policy
    }

    env = {
      MANAGEMENT_TRACING_ENABLED = "false"
      # The chart renders config.spring.datasource straight into a ConfigMap, so the password is
      # injected as an environment variable instead: Spring Boot gives it precedence over YAML.
      SPRING_DATASOURCE_PASSWORD = local.server_database.password
    }

    config = {
      ldesServer = {
        hostName = local.ldes_server_public_url
      }

      streams = local.streams

      spring = {
        datasource = {
          url      = local.server_jdbc_url
          username = local.server_database.username
        }
      }

      extraConfig = var.ldes_server_extra_config
    }

    # Use the external database instead of the chart's development-only PostgreSQL.
    postgres = {
      enabled = false
    }

    resources = {
      requests = var.ldes_server_resources.requests
      limits   = var.ldes_server_resources.limits
    }

    service = {
      type = "ClusterIP"
    }

    ingress = {
      enabled     = var.ingress.enabled
      className   = var.ingress.class_name
      annotations = var.ingress.annotations

      hosts = [
        {
          host = var.ingress.host

          paths = [
            {
              path       = "/"
              pathType   = "Prefix"
              portNumber = 8080
            },
          ]
        },
      ]

      tls = var.ingress.tls_secret == null ? [] : [
        {
          secretName = var.ingress.tls_secret
          hosts      = [var.ingress.host]
        },
      ]
    }
  }
}

resource "helm_release" "ldes_server" {
  name      = var.ldes_server_release_name
  namespace = local.namespace

  repository = var.chart_repository
  chart      = "openldes-server"
  version    = var.ldes_server_chart_version

  atomic          = var.helm_atomic
  cleanup_on_fail = var.helm_atomic
  wait            = true
  wait_for_jobs   = true
  timeout         = var.helm_timeout

  values = [
    yamlencode(local.ldes_server_values),
    yamlencode(var.ldes_server_extra_values),
  ]

  depends_on = [
    kubernetes_job_v1.bootstrap,
  ]
}
