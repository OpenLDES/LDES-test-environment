output "id" {
  description = "ID of the managed PostgreSQL cluster."
  value       = ovh_cloud_project_database.this.id
}

output "status" {
  description = "Current status of the cluster."
  value       = ovh_cloud_project_database.this.status
}

output "engine_version" {
  description = "PostgreSQL version running on the cluster."
  value       = ovh_cloud_project_database.this.version
}

output "host" {
  description = "Hostname of the primary PostgreSQL endpoint."
  value       = local.endpoint.domain
}

output "port" {
  description = "Port of the primary PostgreSQL endpoint."
  value       = local.endpoint.port
}

output "ssl_mode" {
  description = "sslmode value to use in connection strings (\"require\" or \"disable\")."
  value       = local.ssl_mode
}

output "admin_username" {
  description = "Name of the managed superuser, or null when manage_admin_user is false."
  value       = var.manage_admin_user ? ovh_cloud_project_database_postgresql_user.admin[0].name : null
}

output "admin_password" {
  description = "Password of the managed superuser, or null when manage_admin_user is false."
  value       = var.manage_admin_user ? ovh_cloud_project_database_postgresql_user.admin[0].password : null
  sensitive   = true
}
