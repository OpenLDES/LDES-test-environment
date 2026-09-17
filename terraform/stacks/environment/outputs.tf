output "environment_name" {
  description = "Name of the test environment."
  value       = var.environment_name
}

output "namespace" {
  description = "Namespace the environment is deployed in."
  value       = module.ldes_stack.namespace
}

output "ldes_server_url" {
  description = "Public base URL of the LDES server. The load test derives every ingest and view URL from it."
  value       = module.ldes_stack.ldes_server_url
}

output "stream_names" {
  description = "Names of the event streams under test."
  value       = module.ldes_stack.stream_names
}

output "streams" {
  description = "Per stream ingest endpoint, views and sink table."
  value       = module.ldes_stack.streams
}

output "view_urls" {
  description = "Every view of every stream, used to wait for a fully configured LDES server."
  value       = module.ldes_stack.view_urls
}

output "sink_tables" {
  description = "Tables LDIO replicates the members into."
  value       = module.ldes_stack.sink_tables
}

output "admin_url" {
  description = "Base URL of the LDES server admin API."
  value       = module.ldes_stack.admin_url
}

output "sink_database_uri" {
  description = "PostgreSQL connection URI of the sink database, used to verify replication after a load test."
  value       = module.ldes_stack.sink_database.uri
  sensitive   = true
}

output "managed_database" {
  description = "Whether the environment uses the shared managed PostgreSQL cluster."
  value       = local.managed_database
}
