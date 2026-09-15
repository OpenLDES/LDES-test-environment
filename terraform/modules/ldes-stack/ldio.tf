locals {
  ldes_client_source_url = coalesce(var.ldio_ldes_server_url, local.ldes_server_public_url)

  default_sink_sparql_query = <<-SPARQL
    PREFIX dcterms: <http://purl.org/dc/terms/>
    PREFIX lt: <${var.member_vocabulary}>

    SELECT ?version_id ?member_id ?created_at ?value
    WHERE {
        ?version_id dcterms:isVersionOf ?member_id ;
                    dcterms:created ?created_at ;
                    lt:value ?value .
    }
  SPARQL

  sink_sparql_query = coalesce(var.sink_sparql_query, local.default_sink_sparql_query)

  ldes_client_config = merge(
    {
      urls            = ["${local.ldes_client_source_url}/${var.event_stream_name}/${var.view_name}"]
      "source-format" = "text/turtle"
      state           = var.ldes_client_state
    },
    # keep-state is not applicable to the in-memory state.
    var.ldes_client_state == "memory" ? {} : { "keep-state" = true },
  )

  default_pipelines = [
    {
      name        = "ldes-to-postgres"
      description = "Replicates the ${var.event_stream_name} event stream from the LDES server into the ${var.sink_table_name} PostgreSQL table."

      input = {
        name   = "Ldio:LdesClient"
        config = local.ldes_client_config
      }

      outputs = [
        {
          name = "Ldio:LdioRdbOut"

          config = {
            "table-name"                     = var.sink_table_name
            "sparql-select-query"            = local.sink_sparql_query
            "ignore-duplicate-key-exception" = true
          }
        },
      ]
    },
  ]

  pipelines = var.ldio_pipelines != null ? var.ldio_pipelines : local.default_pipelines

  ldio_values = {
    replicaCount = 1

    fullnameOverride = var.ldio_release_name

    image = {
      repository = var.ldio_image.repository
      tag        = var.ldio_image.tag
      pullPolicy = var.ldio_image.pull_policy
    }

    config = {
      orchestrator = {
        directory = "/ldio/pipelines"
        pipelines = local.pipelines
      }

      extraConfig = {
        server = {
          port = 8080
        }

        logging = {
          level = {
            root           = var.ldio_log_level
            "org.openldes" = "INFO"
          }
        }

        # Both Ldio:LdioRdbOut and the PostgreSQL state of the LDES client read the standard
        # Spring Boot datasource properties.
        spring = {
          datasource = {
            url      = local.ldio_jdbc_url
            username = local.ldio_database.username
            password = local.ldio_database.password
          }
        }
      }
    }

    # Use the external database instead of the chart's development-only PostgreSQL.
    postgres = {
      enabled = false
    }

    service = {
      type = "ClusterIP"
      port = 8080
    }

    resources = {
      requests = var.ldio_resources.requests
      limits   = var.ldio_resources.limits
    }
  }
}

resource "helm_release" "ldio" {
  name      = var.ldio_release_name
  namespace = local.namespace

  repository = var.chart_repository
  chart      = "openldes-ldio"
  version    = var.ldio_chart_version

  atomic          = var.helm_atomic
  cleanup_on_fail = var.helm_atomic
  wait            = true
  timeout         = var.helm_timeout

  values = [
    yamlencode(local.ldio_values),
    yamlencode(var.ldio_extra_values),
  ]

  depends_on = [
    # The sink table must exist before Ldio:LdioRdbOut starts, and the event stream must exist
    # before the LDES client starts polling it.
    kubernetes_job_v1.bootstrap,
    helm_release.ldes_server,
  ]
}
