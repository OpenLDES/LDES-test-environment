module "ingress_nginx" {
  source = "../../modules/ingress-nginx"

  chart_version       = var.ingress_nginx_chart_version
  replica_count       = var.ingress_nginx_replica_count
  service_annotations = var.ingress_nginx_service_annotations
  proxy_body_size     = var.proxy_body_size
}
