locals {
  ldes_client_source_url = coalesce(var.ldio_ldes_server_url, local.ldes_server_public_url)

  ldes_client_base_config = merge(
    {
      "source-format" = "text/turtle"
      state           = var.ldes_client_state
    },
    # keep-state is not applicable to the in-memory state.
    var.ldes_client_state == "memory" ? {} : { "keep-state" = true },

    # The LDES client keeps its own replication state and reads its connection details from these
    # properties only; unlike Ldio:LdioRdbOut it ignores the Spring Boot datasource.
    #
    # Note that the SQL state of the LDES client uses fixed, undiscriminated table names, so two
    # pipelines pointing at the same database would consume each other's members. The variable
    # therefore only allows a SQL state when there is a single pipeline.
    var.ldes_client_state == "postgres" ? {
      postgres = {
        url      = local.ldio_jdbc_url
        username = local.ldio_database.username
        password = local.ldio_database.password
      }
    } : {},
  )

  # One pipeline per event stream: an LDES client replicating the paged view of the stream, and an
  # Ldio:LdioRdbOut writing every member into the table of that stream.
  pipelines = [
    for stream in local.catalog.streams : {
      name        = "${stream.name}-to-postgres"
      description = "Replicates the ${stream.name} event stream into the ${stream.sink.table} PostgreSQL table."

      input = {
        name = "Ldio:LdesClient"

        config = merge(local.ldes_client_base_config, {
          urls = ["${local.ldes_client_source_url}/${stream.name}/${stream.replicationView}"]
        })
      }

      outputs = [
        {
          name = "Ldio:LdioRdbOut"

          config = {
            "table-name"                     = stream.sink.table
            "sparql-select-query"            = local.sink_queries[stream.name]
            "ignore-duplicate-key-exception" = true
          }
        },
      ]
    }
  ]

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

        # Ldio:LdioRdbOut writes the members through the standard Spring Boot datasource. The LDES
        # client state is configured separately, through the pipeline's postgres properties.
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
