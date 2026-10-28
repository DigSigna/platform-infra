# modules/database

Este módulo **no crea** la base de datos. Apunta, vía `terraform import`, a un
`digitalocean_database_cluster` MySQL que ya existe (`bitacoradigital-database-...`).
El objetivo es poder gestionarla con Terraform (leer outputs, aplicar
firewall/usuarios a futuro, etc.) sin tocar el recurso real.

## Antes de importar: sacar los valores reales

Con `doctl` autenticado contra la cuenta correcta:

```sh
doctl databases list -o json | jq '.[] | {id, name, engine, version, size, region, num_nodes, private_network_uuid, tags}'
```

Ubicá el cluster `bitacoradigital-database-...` y copiá esos valores exactos
a las variables de este módulo (`name`, `engine`, `engine_version`, `size`,
`region`, `node_count`, `private_network_uuid`, `tags`) en el `.tfvars` del entorno
(`environments/prod/terraform.tfvars`). Si no coinciden con el estado real,
el primer `plan` después del import va a mostrar un diff — en el peor caso,
uno que implique replace.

## Import

1. Declarar el módulo en el entorno (`environments/prod/main.tf`) con las
   variables ya completadas con los valores reales.
2. Correr `terraform init` (ver README del entorno para el backend).
3. Importar el recurso real al estado, usando el **ID** (UUID) del cluster,
   no el nombre:

   ```sh
   terraform import 'module.database.digitalocean_database_cluster.this' <database-cluster-id>
   ```

4. Correr `terraform plan` inmediatamente después. El resultado esperado es
   **"No changes."** Si aparece cualquier diff, PARAR: ajustar las variables
   para que coincidan con el recurso real antes de aplicar nada. Nunca
   aplicar un plan que muestre un replace sobre este recurso.

## Por qué `prevent_destroy = true`

El resource tiene `lifecycle { prevent_destroy = true }`. Es intencional:
ni un `terraform destroy`, ni un cambio de variable que Terraform interprete
como "hay que recrear este recurso", van a poder borrar esta base de datos
por accidente. Si alguna vez hay que destruirla de verdad (migración
completa, baja del servicio), hay que sacar esa línea a propósito, en un
commit separado, con confirmación explícita — no antes.

## Fuera de alcance de este módulo (por ahora)

- Usuarios y bases lógicas dentro del cluster (`digitalocean_database_user`,
  `digitalocean_database_db`) — si ya existen, también requieren su propio
  `terraform import` antes de declararlos aquí.
- Reglas de firewall (`digitalocean_database_firewall`) — mismo criterio: si
  ya hay reglas aplicadas manualmente, hay que importarlas antes de que
  Terraform las gestione, o el primer apply las pisa.
- Mover la base a la VPC nueva del módulo `network`. Está fuera de alcance
  a propósito (ver decisión del repo): esta base queda en su red actual.
