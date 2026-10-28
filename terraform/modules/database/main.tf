# Este recurso representa una base de datos que YA EXISTE en DigitalOcean.
# No se crea desde cero: se importa (ver README.md de este módulo). Los
# valores de las variables deben reflejar la configuración real y actual
# del cluster, para que el primer `terraform plan` después del import
# salga limpio (sin diffs) y nunca dispare un replace.
resource "digitalocean_database_cluster" "this" {
  name       = var.name
  engine     = var.engine
  version    = var.engine_version
  size       = var.size
  region     = var.region
  node_count = var.node_count

  private_network_uuid = var.private_network_uuid

  tags = var.tags

  lifecycle {
    # Última línea de defensa: ningún plan/apply de este módulo puede
    # destruir la base de datos productiva, ni siquiera por error humano
    # o un mismatch de variables que Terraform interprete como replace.
    prevent_destroy = true
  }
}
