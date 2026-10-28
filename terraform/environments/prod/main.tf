module "network" {
  source = "../../modules/network"

  name     = var.vpc_name
  region   = var.region
  ip_range = var.vpc_ip_range
}

module "doks" {
  source = "../../modules/doks"

  name                = var.doks_name
  region              = var.region
  vpc_uuid            = module.network.vpc_id
  k8s_version         = var.doks_version
  k8s_version_prefix  = var.doks_version_prefix
  ha                  = var.doks_ha
  node_pool_name      = var.node_pool_name
  node_size           = var.node_size
  node_pool_min_nodes = var.node_pool_min_nodes
  node_pool_max_nodes = var.node_pool_max_nodes
  tags                = var.tags
}

# Recurso existente: importar antes de aplicar. Ver modules/database/README.md.
module "database" {
  source = "../../modules/database"

  name                 = var.db_name
  engine               = var.db_engine
  engine_version       = var.db_version
  size                 = var.db_size
  region               = var.db_region
  node_count           = var.db_node_count
  private_network_uuid = var.db_private_network_uuid
  tags                 = var.db_tags
}
