output "service_name" {
  description = "OVHcloud Public Cloud project the platform lives in."
  value       = var.service_name
}

output "region" {
  description = "Region of the Kubernetes cluster."
  value       = module.kubernetes.region
}

output "cluster_id" {
  description = "ID of the Managed Kubernetes cluster."
  value       = module.kubernetes.id
}

output "cluster_name" {
  description = "Name of the Managed Kubernetes cluster."
  value       = module.kubernetes.name
}

output "cluster_version" {
  description = "Kubernetes version running on the cluster."
  value       = module.kubernetes.version
}

output "kubeconfig" {
  description = "Raw kubeconfig for the cluster. Consumed by the load test job and by operators."
  value       = module.kubernetes.kubeconfig
  sensitive   = true
}

output "cluster_host" {
  description = "Kubernetes API server URL."
  value       = module.kubernetes.host
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "PEM-encoded CA certificate of the API server."
  value       = module.kubernetes.cluster_ca_certificate
  sensitive   = true
}

output "cluster_client_certificate" {
  description = "PEM-encoded client certificate for the API server."
  value       = module.kubernetes.client_certificate
  sensitive   = true
}

output "cluster_client_key" {
  description = "PEM-encoded client key for the API server."
  value       = module.kubernetes.client_key
  sensitive   = true
}

output "database_enabled" {
  description = "Whether a managed PostgreSQL cluster is available for the test environments."
  value       = var.create_database
}

output "database_cluster_id" {
  description = "ID of the managed PostgreSQL cluster, or null when disabled."
  value       = one(module.postgresql[*].id)
}

output "database_host" {
  description = "Hostname of the managed PostgreSQL endpoint, or null when disabled."
  value       = one(module.postgresql[*].host)
}

output "database_port" {
  description = "Port of the managed PostgreSQL endpoint, or null when disabled."
  value       = one(module.postgresql[*].port)
}

output "database_ssl_mode" {
  description = "sslmode to use when connecting to the managed PostgreSQL cluster."
  value       = one(module.postgresql[*].ssl_mode)
}

output "database_admin_username" {
  description = "Superuser of the managed PostgreSQL cluster, or null when disabled."
  value       = one(module.postgresql[*].admin_username)
}

output "database_admin_password" {
  description = "Superuser password of the managed PostgreSQL cluster, or null when disabled."
  value       = one(module.postgresql[*].admin_password)
  sensitive   = true

  # A null password is silently dropped from the state, so dependent stacks would only fail much
  # later with "This object does not have an attribute named database_admin_password".
  precondition {
    condition     = !var.create_database || one(module.postgresql[*].admin_password) != null
    error_message = "The managed PostgreSQL cluster returned no admin password. Change database_admin_password_reset to force OVHcloud to issue one."
  }
}
