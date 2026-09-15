variable "platform_remote_state" {
  description = <<-EOT
    Backend configuration used to read the outputs of the platform stack. The same values as the
    -backend-config of that stack, minus any credentials, which are read from the environment.

    Typed loosely because the S3 backend takes nested attributes such as `endpoints.s3`.
  EOT

  type = any
}

variable "ingress_nginx_chart_version" {
  description = "Version of the ingress-nginx Helm chart."
  type        = string
  default     = "4.13.9"
}

variable "ingress_nginx_replica_count" {
  description = "Number of ingress controller replicas. Keep at least two so a load test is not skewed by a single restarting pod."
  type        = number
  default     = 2
}

variable "ingress_nginx_service_annotations" {
  description = "Annotations on the ingress controller LoadBalancer service, e.g. to pick an OVHcloud load balancer flavour."
  type        = map(string)
  default     = {}
}

variable "proxy_body_size" {
  description = "Maximum ingest request size accepted by the ingress controller."
  type        = string
  default     = "32m"
}
