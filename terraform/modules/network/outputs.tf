output "vpc_id" {
  description = "UUID de la VPC, usado por otros módulos (doks, etc.) para desplegar dentro de esta red"
  value       = digitalocean_vpc.this.id
}

output "vpc_urn" {
  value = digitalocean_vpc.this.urn
}

output "ip_range" {
  value = digitalocean_vpc.this.ip_range
}
