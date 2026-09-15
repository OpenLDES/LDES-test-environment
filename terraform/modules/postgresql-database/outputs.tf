output "connection" {
  description = "Everything needed to connect to the database, ready to be passed to the ldes-stack module."

  value = {
    host     = var.host
    port     = var.port
    database = ovh_cloud_project_database_database.this.name
    username = local.username
    password = local.password
    ssl_mode = var.ssl_mode
    jdbc_url = local.jdbc_url
    uri      = local.uri
  }

  sensitive = true
}

output "database_name" {
  description = "Name of the created logical database."
  value       = ovh_cloud_project_database_database.this.name
}

output "jdbc_url" {
  description = "JDBC URL pointing at the created database."
  value       = local.jdbc_url
}
