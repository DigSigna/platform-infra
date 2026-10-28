variable "name" {
  description = "Nombre del Cloud Firewall"
  type        = string
}

variable "target_tag" {
  description = "Tag de DigitalOcean aplicada a los droplets del node pool de DOKS a los que se les aplica este firewall (debe coincidir con un tag real del node pool, no inventado)"
  type        = string
}

variable "doks_cluster_id" {
  description = "ID del cluster DOKS (module.doks.cluster_id), usado para permitir tráfico intra-cluster (pods, kube-proxy, health checks) vía source_kubernetes_ids, sin necesidad de abrir esos puertos a Internet"
  type        = string
}

variable "public_ports" {
  description = "Puertos públicos de entrada, expuestos solo para el futuro Ingress del cluster (nunca para los backends individuales)"
  type        = list(string)
  default     = ["80", "443"]
}
