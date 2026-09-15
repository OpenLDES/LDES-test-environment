output "id" {
  description = "ID of the Managed Kubernetes cluster."
  value       = ovh_cloud_project_kube.this.id
}

output "name" {
  description = "Name of the Managed Kubernetes cluster."
  value       = ovh_cloud_project_kube.this.name
}

output "region" {
  description = "Region the cluster is deployed in."
  value       = ovh_cloud_project_kube.this.region
}

output "version" {
  description = "Kubernetes version running on the cluster."
  value       = ovh_cloud_project_kube.this.version
}

output "status" {
  description = "Current status of the cluster, normally READY."
  value       = ovh_cloud_project_kube.this.status
}

output "nodepools" {
  description = "Node pool IDs keyed by node pool name."
  value       = { for name, pool in ovh_cloud_project_kube_nodepool.this : name => pool.id }
}

output "kubeconfig" {
  description = "Raw kubeconfig file contents for the cluster."
  value       = ovh_cloud_project_kube.this.kubeconfig
  sensitive   = true
}

output "host" {
  description = "Kubernetes API server URL."
  value       = ovh_cloud_project_kube.this.kubeconfig_attributes[0].host
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "PEM-encoded CA certificate of the Kubernetes API server."
  value       = base64decode(ovh_cloud_project_kube.this.kubeconfig_attributes[0].cluster_ca_certificate)
  sensitive   = true
}

output "client_certificate" {
  description = "PEM-encoded client certificate used to authenticate against the API server."
  value       = base64decode(ovh_cloud_project_kube.this.kubeconfig_attributes[0].client_certificate)
  sensitive   = true
}

output "client_key" {
  description = "PEM-encoded client key used to authenticate against the API server."
  value       = base64decode(ovh_cloud_project_kube.this.kubeconfig_attributes[0].client_key)
  sensitive   = true
}
