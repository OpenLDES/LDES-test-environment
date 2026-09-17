resource "random_password" "in_cluster_postgres" {
  count = local.use_in_cluster_postgres ? 1 : 0

  length  = 24
  special = false
}

# --------------------------------------------------------------------------------------------
# Throwaway in-cluster PostgreSQL
#
# Only deployed when no external database is supplied. Unlike the `postgres.enabled` option of
# the OpenLDES charts this instance is owned by Terraform, which makes it possible to create the
# LDIO sink table *before* LDIO starts -- Ldio:LdioRdbOut requires the table to already exist.
# --------------------------------------------------------------------------------------------

resource "kubernetes_secret_v1" "in_cluster_postgres" {
  count = local.use_in_cluster_postgres ? 1 : 0

  metadata {
    name      = local.in_cluster_service_name
    namespace = local.namespace
    labels    = local.common_labels
  }

  data = {
    POSTGRES_USER     = var.in_cluster_postgres.username
    POSTGRES_PASSWORD = random_password.in_cluster_postgres[0].result
    POSTGRES_DB       = var.in_cluster_postgres.server_database
  }
}

resource "kubernetes_persistent_volume_claim_v1" "in_cluster_postgres" {
  count = local.use_in_cluster_postgres ? 1 : 0

  metadata {
    name      = local.in_cluster_service_name
    namespace = local.namespace
    labels    = local.common_labels
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.in_cluster_postgres.storage_class

    resources {
      requests = {
        storage = var.in_cluster_postgres.storage
      }
    }
  }

  wait_until_bound = false
}

resource "kubernetes_deployment_v1" "in_cluster_postgres" {
  count = local.use_in_cluster_postgres ? 1 : 0

  metadata {
    name      = local.in_cluster_service_name
    namespace = local.namespace
    labels    = merge(local.common_labels, { "app.kubernetes.io/name" = local.in_cluster_service_name })
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        "app.kubernetes.io/name" = local.in_cluster_service_name
      }
    }

    template {
      metadata {
        labels = merge(local.common_labels, { "app.kubernetes.io/name" = local.in_cluster_service_name })
      }

      spec {
        container {
          name  = "postgres"
          image = var.in_cluster_postgres.image

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.in_cluster_postgres[0].metadata[0].name
            }
          }

          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }

          port {
            name           = "postgres"
            container_port = 5432
          }

          readiness_probe {
            exec {
              command = ["pg_isready", "-U", var.in_cluster_postgres.username]
            }

            initial_delay_seconds = 10
            period_seconds        = 5
          }

          resources {
            requests = var.in_cluster_postgres.resource_requests
            limits   = var.in_cluster_postgres.resource_limits
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/lib/postgresql/data"
          }
        }

        volume {
          name = "data"

          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.in_cluster_postgres[0].metadata[0].name
          }
        }
      }
    }
  }

  wait_for_rollout = true

  timeouts {
    create = "15m"
    update = "15m"
  }
}

resource "kubernetes_service_v1" "in_cluster_postgres" {
  count = local.use_in_cluster_postgres ? 1 : 0

  metadata {
    name      = local.in_cluster_service_name
    namespace = local.namespace
    labels    = local.common_labels
  }

  spec {
    selector = {
      "app.kubernetes.io/name" = local.in_cluster_service_name
    }

    port {
      name        = "postgres"
      port        = 5432
      target_port = "postgres"
    }
  }
}

# --------------------------------------------------------------------------------------------
# Sink table bootstrap
# --------------------------------------------------------------------------------------------

locals {
  # The sink schema is generated from the catalogue; see catalog.tf.
  sink_ddl = join("\n\n", compact([local.sink_table_ddl, var.sink_schema_ddl]))

  maintenance_uri = "postgresql://${urlencode(local.ldio_database.username)}:${urlencode(local.ldio_database.password)}@${local.ldio_database.host}:${local.ldio_database.port}/postgres?sslmode=${coalesce(local.ldio_database.ssl_mode, "require")}"

  bootstrap_script = <<-SH
    #!/bin/sh
    set -eu

    %{~if local.use_in_cluster_postgres}
    # The LDIO database does not exist yet, so wait on the maintenance database.
    WAIT_URI="$MAINTENANCE_URI"
    %{~else}
    # The managed database already exists, so wait on it directly. Managed PostgreSQL offerings
    # do not necessarily expose a "postgres" maintenance database.
    WAIT_URI="$LDIO_URI"
    %{~endif}

    echo "Waiting for PostgreSQL to accept connections..."
    attempt=0
    until psql "$WAIT_URI" -c 'SELECT 1' >/dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 60 ]; then
            echo "PostgreSQL did not become available in time" >&2
            exit 1
        fi
        sleep 5
    done

    %{~if local.use_in_cluster_postgres}
    echo "Ensuring database ${local.ldio_database.database} exists..."
    psql "$MAINTENANCE_URI" -v ON_ERROR_STOP=1 -tAc \
        "SELECT 1 FROM pg_database WHERE datname = '${local.ldio_database.database}'" \
        | grep -q 1 \
        || psql "$MAINTENANCE_URI" -v ON_ERROR_STOP=1 -c 'CREATE DATABASE "${local.ldio_database.database}"'
    %{~endif}

    echo "Applying sink schema to ${local.ldio_database.database}..."
    psql "$LDIO_URI" -v ON_ERROR_STOP=1 -f /bootstrap/sink.sql

    echo "Bootstrap completed."
  SH
}

resource "kubernetes_secret_v1" "bootstrap" {
  metadata {
    name      = "ldes-database-bootstrap"
    namespace = local.namespace
    labels    = local.common_labels
  }

  data = {
    MAINTENANCE_URI = local.maintenance_uri
    LDIO_URI        = local.ldio_admin_uri
  }
}

resource "kubernetes_config_map_v1" "bootstrap" {
  metadata {
    name      = "ldes-database-bootstrap"
    namespace = local.namespace
    labels    = local.common_labels
  }

  data = {
    "bootstrap.sh" = local.bootstrap_script
    "sink.sql"     = local.sink_ddl
  }
}

resource "kubernetes_job_v1" "bootstrap" {
  # Jobs are immutable, so the name carries a digest of what the job actually runs. Changing the
  # DDL therefore replaces the job instead of failing the apply.
  metadata {
    name      = "ldes-database-bootstrap-${substr(sha256("${local.bootstrap_script}${local.sink_ddl}"), 0, 10)}"
    namespace = local.namespace
    labels    = local.common_labels
  }

  spec {
    backoff_limit = 6

    template {
      metadata {
        labels = local.common_labels
      }

      spec {
        restart_policy = "OnFailure"

        container {
          name    = "bootstrap"
          image   = var.in_cluster_postgres.image
          command = ["/bin/sh", "/bootstrap/bootstrap.sh"]

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.bootstrap.metadata[0].name
            }
          }

          volume_mount {
            name       = "bootstrap"
            mount_path = "/bootstrap"
            read_only  = true
          }
        }

        volume {
          name = "bootstrap"

          config_map {
            name         = kubernetes_config_map_v1.bootstrap.metadata[0].name
            default_mode = "0555"
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "15m"
    update = "15m"
  }

  depends_on = [
    kubernetes_deployment_v1.in_cluster_postgres,
    kubernetes_service_v1.in_cluster_postgres,
  ]
}
