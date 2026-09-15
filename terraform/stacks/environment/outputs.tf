output "environment_name" {
  description = "Name of the test environment."
  value       = var.environment_name
}

output "namespace" {
  description = "Namespace the environment is deployed in."
  value       = module.ldes_stack.namespace
}

output "ldes_server_url" {
  description = "Public base URL of the LDES server."
  value       = module.ldes_stack.ldes_server_url
}

output "ingest_url" {
  description = "URL the load test posts members to."
  value       = module.ldes_stack.ingest_url
}

output "view_url" {
  description = "URL of the paged view LDIO replicates from."
  value       = module.ldes_stack.view_url
}

output "admin_url" {
  description = "Base URL of the LDES server admin API."
  value       = module.ldes_stack.admin_url
}

output "event_stream_name" {
  description = "Name of the event stream under test."
  value       = module.ldes_stack.event_stream_name
}

output "member_vocabulary" {
  description = "Namespace IRI the load test must emit its member properties in."
  value       = module.ldes_stack.member_vocabulary
}

output "sink_table_name" {
  description = "Table LDIO replicates the members into."
  value       = module.ldes_stack.sink_table_name
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
