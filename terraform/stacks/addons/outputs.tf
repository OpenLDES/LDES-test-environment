output "ingress_class_name" {
  description = "IngressClass that per-environment Ingress resources must reference."
  value       = module.ingress_nginx.ingress_class_name
}

output "ingress_namespace" {
  description = "Namespace the ingress controller runs in."
  value       = module.ingress_nginx.namespace
}

output "ingress_service_name" {
  description = "Name of the ingress controller LoadBalancer service."
  value       = module.ingress_nginx.service_name
}

output "load_balancer_ip" {
  description = "Public IPv4 address of the ingress load balancer."
  value       = module.ingress_nginx.load_balancer_ip
}

output "load_balancer_hostname" {
  description = "Public hostname of the ingress load balancer, when OVHcloud provides one."
  value       = module.ingress_nginx.load_balancer_hostname
}

check "load_balancer_is_provisioned" {
  assert {
    condition     = module.ingress_nginx.load_balancer_ip != "" || module.ingress_nginx.load_balancer_hostname != ""
    error_message = "The ingress load balancer has no public address yet. OVHcloud provisions it asynchronously; re-run this stack in a few minutes so the address is recorded in the state."
  }
}
