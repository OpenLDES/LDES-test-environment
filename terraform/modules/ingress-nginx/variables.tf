variable "namespace" {
  description = "Namespace the ingress controller is installed in."
  type        = string
  default     = "ingress-nginx"
}

variable "release_name" {
  description = "Helm release name of the ingress controller."
  type        = string
  default     = "ingress-nginx"
}

variable "chart_version" {
  description = "Version of the ingress-nginx Helm chart."
  type        = string
  default     = "4.13.9"
}

variable "ingress_class_name" {
  description = "Name of the IngressClass created by the controller."
  type        = string
  default     = "nginx"
}

variable "replica_count" {
  description = "Number of ingress controller replicas."
  type        = number
  default     = 2
}

variable "service_annotations" {
  description = "Annotations applied to the controller LoadBalancer service, e.g. to select an OVHcloud load balancer flavour."
  type        = map(string)
  default     = {}
}

variable "proxy_body_size" {
  description = "Maximum request body size accepted by the controller. LDES ingest requests can be large, so this is deliberately generous."
  type        = string
  default     = "32m"
}

variable "extra_values" {
  description = "Additional Helm values merged on top of the defaults, as a map."
  type        = any
  default     = {}
}
