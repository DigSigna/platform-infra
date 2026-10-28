# terraform/

Infraestructura de DigitalOcean para la plataforma, organizada en módulos
reutilizables y un entorno (`environments/prod`) que los conecta.

```
terraform/
  modules/
    network/    # VPC propia
    doks/       # cluster DOKS + node pool con autoscale
    database/   # apunta (vía import) a la MySQL gestionada que ya existe
  environments/
    prod/       # wiring de los tres módulos + backend remoto
```

## Orden de trabajo

1. **Backend**: copiar `environments/prod/backend.hcl.example` a
   `backend.hcl` (gitignored) con los datos reales del Space, y exportar
   `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` con las keys de Spaces
   (no de AWS).
2. **Credenciales de DO**: exportar `DIGITALOCEAN_TOKEN` en la shell. Nunca
   pegarlo en un `.tfvars` ni en el chat.
3. **Variables**: copiar `environments/prod/terraform.tfvars.example` a
   `terraform.tfvars` (gitignored). Las de `network`/`doks` son nombres
   nuevos a elección; las de `database` (`db_*`) tienen que ser el reflejo
   exacto del cluster MySQL real — ver `modules/database/README.md` para
   cómo sacarlas con `doctl` antes de tocar nada.
4. **Init**:
   ```sh
   cd environments/prod
   terraform init -backend-config=backend.hcl
   ```
5. **Red + cluster primero**: aplicar network y doks antes de declarar/
   importar database, para no mezclar la creación de recursos nuevos con
   el import de uno existente en el mismo apply.
   ```sh
   terraform apply -target=module.network -target=module.doks
   ```
6. **Database**: importar el cluster existente (una sola vez) y verificar
   que el plan posterior salga limpio. Ver `modules/database/README.md`
   para el comando exacto y qué hacer si el plan muestra un diff.
7. **Apply completo**: una vez que `plan` no muestra sorpresas sobre
   `module.database`, recién ahí `terraform apply` sin `-target`.

## Decisiones de diseño

- La VPC nueva (`module.network`) es para el DOKS cluster. La base de datos
  existente **no se migra** a esta VPC como parte de este trabajo — queda
  en su red actual. Si en el futuro se decide moverla, es un cambio
  explícito y separado sobre `private_network_uuid` en `modules/database`.
- `modules/database` tiene `lifecycle { prevent_destroy = true }` como red
  de seguridad: ningún apply de este repo puede borrar la base productiva
  por accidente.
- El node pool de DOKS usa `auto_scale = true` con `min_nodes`/`max_nodes`;
  no se setea `node_count` porque el provider lo rechaza junto con
  `auto_scale`.
