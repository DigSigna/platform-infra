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

# PEM text, decoded (not the base64 form kubeconfig's certificate-authority-data
# carries) -- deploy.yml's `base64 -d` step expects the GitHub secret to hold
# the base64 form, so re-encode this before loading it into DOKS_CA_CERT.
output "doks_cluster_ca_certificate" {
  value     = module.doks.cluster_ca_certificate
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

output "firewall_id" {
  value = module.firewall.firewall_id
}
