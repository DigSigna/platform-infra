data "digitalocean_kubernetes_versions" "this" {
  count          = var.k8s_version == "" ? 1 : 0
  version_prefix = var.k8s_version_prefix
}

locals {
  k8s_version = var.k8s_version != "" ? var.k8s_version : data.digitalocean_kubernetes_versions.this[0].latest_version
}

resource "digitalocean_kubernetes_cluster" "this" {
  name          = var.name
  region        = var.region
  version       = local.k8s_version
  vpc_uuid      = var.vpc_uuid
  ha            = var.ha
  auto_upgrade  = var.auto_upgrade
  surge_upgrade = var.surge_upgrade
  tags          = var.tags

  maintenance_policy {
    day        = var.maintenance_day
    start_time = var.maintenance_start_time
  }

  # Node pool con autoscale: node_count no se setea a propósito, es
  # incompatible con auto_scale = true (el provider lo rechaza si están
  # ambos presentes).
  node_pool {
    name       = var.node_pool_name
    size       = var.node_size
    auto_scale = true
    min_nodes  = var.node_pool_min_nodes
    max_nodes  = var.node_pool_max_nodes
    labels     = var.node_pool_labels
    tags       = var.tags
  }
}
