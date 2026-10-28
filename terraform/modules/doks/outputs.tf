output "cluster_id" {
  value = digitalocean_kubernetes_cluster.this.id
}

output "cluster_urn" {
  value = digitalocean_kubernetes_cluster.this.urn
}

output "endpoint" {
  value = digitalocean_kubernetes_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  value     = digitalocean_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate
  sensitive = true
}

output "kube_config_raw" {
  description = "kubeconfig completo, listo para escribir a un archivo (kubectl --kubeconfig)"
  value       = digitalocean_kubernetes_cluster.this.kube_config[0].raw_config
  sensitive   = true
}

output "node_pool_id" {
  value = digitalocean_kubernetes_cluster.this.node_pool[0].id
}
