# Backend remoto en DigitalOcean Spaces (S3-compatible). El bucket lo crea
# bootstrap/ (aparte, una sola vez). Los valores reales (bucket, region,
# endpoint, credenciales de Spaces) NO van acá — van en backend.hcl
# (gitignored, ver backend.hcl.example) y se pasan con:
#
#   terraform init -backend-config=backend.hcl
#
# Las credenciales de Spaces se leen de AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
# (son keys de Spaces, no de AWS) para no commitearlas ni en backend.hcl.
#
# use_lockfile = true habilita locking nativo del backend S3 (soportado
# desde Terraform 1.10, sin necesitar DynamoDB) — evita que dos
# `terraform apply` corran en paralelo sobre el mismo state.
terraform {
  backend "s3" {
    key                         = "platform-infra/prod/terraform.tfstate"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
    use_lockfile                = true
  }
}
