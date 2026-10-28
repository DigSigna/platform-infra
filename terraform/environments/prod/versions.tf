terraform {
  required_version = ">= 1.6.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = ">= 2.34.0, < 3.0.0"
    }
  }
}

# El token se lee de la variable de entorno DIGITALOCEAN_TOKEN (o
# DIGITALOCEAN_ACCESS_TOKEN) — nunca hardcodeado ni en .tfvars.
provider "digitalocean" {}
