locals {
  # Tag propio del node pool de este cluster, usado por el módulo firewall
  # para saber a qué droplets aplicarse. No es un valor a elección libre:
  # una vez aplicado, hay que confirmar con `doctl compute droplet list
  # --tag-name <este-tag>` que efectivamente etiquetó los nodos.
  doks_node_tag = "${var.doks_name}-nodes"
}

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
  tags                = concat(var.tags, [local.doks_node_tag])
}

# Único punto de entrada público: 80/443 hacia el futuro Ingress. Los 6
# backends nunca se exponen por este firewall — solo api-gateway, detrás
# del Ingress, termina en estos puertos.
module "firewall" {
  source = "../../modules/firewall"

  name            = "${var.doks_name}-ingress"
  target_tag      = local.doks_node_tag
  doks_cluster_id = module.doks.cluster_id
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
