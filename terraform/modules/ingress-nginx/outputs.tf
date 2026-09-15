locals {
  load_balancer = try(data.kubernetes_service_v1.controller.status[0].load_balancer[0].ingress[0], null)

  load_balancer_ip       = try(local.load_balancer.ip, "")
  load_balancer_hostname = try(local.load_balancer.hostname, "")
}

output "namespace" {
  description = "Namespace the ingress controller runs in."
  value       = var.namespace
}

output "service_name" {
  description = "Name of the ingress controller LoadBalancer service."
  value       = data.kubernetes_service_v1.controller.metadata[0].name
}

output "ingress_class_name" {
  description = "IngressClass to reference from Ingress resources."
  value       = var.ingress_class_name
}

output "load_balancer_ip" {
  description = "Public IPv4 address of the load balancer, empty while it is still being provisioned."
  value       = local.load_balancer_ip
}

output "load_balancer_hostname" {
  description = "Public hostname of the load balancer, empty when OVHcloud only exposes an IP."
  value       = local.load_balancer_hostname
}
