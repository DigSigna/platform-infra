# bootstrap/

Crea el Space (bucket S3-compatible) que `environments/*` usan como backend
remoto de Terraform. Es el único directorio de este repo que corre con
**state local** — es intencional: no puede depender del bucket que él mismo
va a crear.

## Cómo correr (una sola vez, y casi nunca más)

```sh
cd bootstrap
export DIGITALOCEAN_TOKEN=...   # exportado en tu shell, nunca en un archivo
cp terraform.tfvars.example terraform.tfvars   # completar bucket_name/region reales
terraform init
terraform apply
```

Después de este primer `apply`, usar los outputs (`bucket_name`, `region`,
`endpoint`) para completar `environments/prod/backend.hcl` (ver
`environments/prod/backend.hcl.example`).

## Después de correrlo: no se vuelve a tocar

Una vez que el bucket existe y los ambientes ya lo usan como backend, este
directorio no debería volver a aplicarse salvo un cambio deliberado sobre el
bucket mismo (ej. agregar una lifecycle rule). No agregar aquí ningún otro
recurso de la plataforma — eso va en `environments/`.

`terraform.tfstate` de este directorio queda local y gitignored. Como es el
único registro de que este bucket está gestionado por Terraform, conviene
guardar una copia en un lugar seguro (gestor de secretos, backup cifrado)
apenas se corra el apply — no es sensible en el sentido de contener
credenciales, pero perderlo significa tener que re-importar el bucket a mano
si algún día hace falta volver a tocarlo con Terraform.

## Spaces access keys (para el backend S3 de los ambientes)

El provider de DigitalOcean no gestiona las access keys de Spaces (son un
sistema de credenciales separado del token de la API). Hay que generarlas a
mano: panel de DO → API → Spaces Keys. El resultado (access key + secret
key) se exporta como `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` en la
shell donde se corra `terraform init`/`apply` de cada ambiente — nunca se
pegan en `backend.hcl` ni en ningún archivo del repo.
