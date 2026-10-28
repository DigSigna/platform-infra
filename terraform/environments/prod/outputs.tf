output "vpc_id" {
  value = module.network.vpc_id
}

output "doks_cluster_id" {
  value = module.doks.cluster_id
}

output "doks_endpoint" {
  value = module.doks.endpoint
}

output "doks_kube_config_raw" {
  value     = module.doks.kube_config_raw
  sensitive = true
}

output "database_cluster_id" {
  value = module.database.cluster_id
}

output "database_private_host" {
  value = module.database.private_host
}

output "database_port" {
  value = module.database.port
}
