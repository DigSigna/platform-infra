output "cluster_id" {
  value = digitalocean_database_cluster.this.id
}

output "urn" {
  value = digitalocean_database_cluster.this.urn
}

output "host" {
  value = digitalocean_database_cluster.this.host
}

output "private_host" {
  value = digitalocean_database_cluster.this.private_host
}

output "port" {
  value = digitalocean_database_cluster.this.port
}

output "user" {
  value     = digitalocean_database_cluster.this.user
  sensitive = true
}

output "password" {
  value     = digitalocean_database_cluster.this.password
  sensitive = true
}

output "uri" {
  value     = digitalocean_database_cluster.this.uri
  sensitive = true
}

output "private_uri" {
  value     = digitalocean_database_cluster.this.private_uri
  sensitive = true
}
