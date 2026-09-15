resource "ovh_cloud_project_database_database" "this" {
  service_name = var.service_name
  cluster_id   = var.cluster_id
  engine       = "postgresql"
  name         = var.name
}

resource "ovh_cloud_project_database_postgresql_user" "this" {
  count = var.create_user ? 1 : 0

  service_name = var.service_name
  cluster_id   = var.cluster_id
  name         = coalesce(var.user_name, var.name)
}

locals {
  username = var.create_user ? ovh_cloud_project_database_postgresql_user.this[0].name : var.admin_username
  password = var.create_user ? ovh_cloud_project_database_postgresql_user.this[0].password : var.admin_password

  query = "sslmode=${var.ssl_mode}"

  jdbc_url = "jdbc:postgresql://${var.host}:${var.port}/${ovh_cloud_project_database_database.this.name}?${local.query}"
  uri      = "postgresql://${urlencode(local.username)}:${urlencode(local.password)}@${var.host}:${var.port}/${ovh_cloud_project_database_database.this.name}?${local.query}"
}
