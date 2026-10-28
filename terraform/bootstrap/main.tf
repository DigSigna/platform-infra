# Bucket (Space) dedicado exclusivamente a guardar el tfstate remoto de
# los ambientes (environments/prod, y los que se agreguen después). No
# guarda nada más.
resource "digitalocean_spaces_bucket" "tfstate" {
  name   = var.bucket_name
  region = var.region
  acl    = "private"

  # Nunca true: este bucket solo debería destruirse a mano, a propósito,
  # después de confirmar que ningún ambiente sigue usándolo como backend.
  force_destroy = false

  # Protege contra un sobre-escritura o borrado accidental del tfstate:
  # permite recuperar una versión anterior del objeto si algo lo corrompe.
  versioning {
    enabled = true
  }
}
