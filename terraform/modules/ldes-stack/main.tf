locals {
  common_labels = merge({
    "app.kubernetes.io/part-of"    = "ldes-test-environment"
    "app.kubernetes.io/managed-by" = "terraform"
  }, var.labels)

  use_in_cluster_postgres = var.ldes_server_database == null && var.ldio_database == null

  in_cluster_service_name = "ldes-postgres"
  in_cluster_host         = "${local.in_cluster_service_name}.${var.namespace}.svc.cluster.local"

  in_cluster_server_database = {
    host     = local.in_cluster_host
    port     = 5432
    database = var.in_cluster_postgres.server_database
    username = var.in_cluster_postgres.username
    password = one(random_password.in_cluster_postgres[*].result)
    ssl_mode = "disable"
  }

  in_cluster_ldio_database = {
    host     = local.in_cluster_host
    port     = 5432
    database = var.in_cluster_postgres.ldio_database
    username = var.in_cluster_postgres.username
    password = one(random_password.in_cluster_postgres[*].result)
    ssl_mode = "disable"
  }

  server_database = local.use_in_cluster_postgres ? local.in_cluster_server_database : var.ldes_server_database
  ldio_database   = local.use_in_cluster_postgres ? local.in_cluster_ldio_database : var.ldio_database

  server_jdbc_url = "jdbc:postgresql://${local.server_database.host}:${local.server_database.port}/${local.server_database.database}?sslmode=${coalesce(local.server_database.ssl_mode, "require")}"
  ldio_jdbc_url   = "jdbc:postgresql://${local.ldio_database.host}:${local.ldio_database.port}/${local.ldio_database.database}?sslmode=${coalesce(local.ldio_database.ssl_mode, "require")}"

  ldio_admin_uri = "postgresql://${urlencode(local.ldio_database.username)}:${urlencode(local.ldio_database.password)}@${local.ldio_database.host}:${local.ldio_database.port}/${local.ldio_database.database}?sslmode=${coalesce(local.ldio_database.ssl_mode, "require")}"

  # Cluster-internal address of the LDES server. LDIO uses this instead of the public ingress so
  # replication traffic never leaves the cluster, and the load test is the only ingress consumer.
  ldes_server_internal_url = "http://${var.ldes_server_release_name}.${var.namespace}.svc.cluster.local:8080"

  ldes_server_public_url = var.ldes_server_host_name
  event_stream_url       = "${local.ldes_server_public_url}/${var.event_stream_name}"
  view_url               = "${local.event_stream_url}/${var.view_name}"
}

resource "kubernetes_namespace_v1" "this" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name   = var.namespace
    labels = local.common_labels
  }
}

locals {
  # Every other resource in this module must wait for the namespace to exist.
  namespace = var.create_namespace ? kubernetes_namespace_v1.this[0].metadata[0].name : var.namespace
}
