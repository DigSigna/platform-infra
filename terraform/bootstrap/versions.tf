terraform {
  required_version = ">= 1.6.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = ">= 2.34.0, < 3.0.0"
    }
  }

  # A propósito SIN bloque backend: este state queda local. Es el único
  # bootstrap de todo el repo que corre así — crea el bucket que todos los
  # demás ambientes van a usar como backend remoto, así que no puede
  # depender de sí mismo. Ver README.md de este directorio.
}

provider "digitalocean" {}
