resource "ovh_cloud_project_kube" "this" {
  service_name = var.service_name
  name         = var.name
  region       = var.region
  version      = var.kubernetes_version
  plan         = var.plan

  kube_proxy_mode = var.kube_proxy_mode
  update_policy   = var.update_policy

  private_network_id       = var.private_network_id
  nodes_subnet_id          = var.nodes_subnet_id
  load_balancers_subnet_id = var.load_balancers_subnet_id
}

resource "ovh_cloud_project_kube_iprestrictions" "this" {
  count = length(var.api_server_ip_restrictions) > 0 ? 1 : 0

  service_name = var.service_name
  kube_id      = ovh_cloud_project_kube.this.id
  ips          = var.api_server_ip_restrictions
}

resource "ovh_cloud_project_kube_nodepool" "this" {
  for_each = var.node_pools

  service_name = var.service_name
  kube_id      = ovh_cloud_project_kube.this.id

  name          = each.key
  flavor_name   = each.value.flavor_name
  desired_nodes = each.value.desired_nodes
  min_nodes     = each.value.min_nodes
  max_nodes     = each.value.max_nodes

  autoscale      = each.value.autoscale
  anti_affinity  = each.value.anti_affinity
  monthly_billed = each.value.monthly_billed

  availability_zones = each.value.availability_zones

  lifecycle {
    # Let the cluster autoscaler own the node count once the pool exists.
    ignore_changes = [desired_nodes]
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}
