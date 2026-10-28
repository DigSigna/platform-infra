output "bucket_name" {
  value = digitalocean_spaces_bucket.tfstate.name
}

output "region" {
  value = digitalocean_spaces_bucket.tfstate.region
}

output "endpoint" {
  description = "Endpoint S3-compatible del Space, para usar en backend.hcl de los ambientes"
  value       = digitalocean_spaces_bucket.tfstate.endpoint
}

output "urn" {
  value = digitalocean_spaces_bucket.tfstate.urn
}
