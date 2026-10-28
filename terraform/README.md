# terraform/

Infraestructura de DigitalOcean para la plataforma, organizada en módulos
reutilizables y un entorno (`environments/prod`) que los conecta. Todo lo
que hay hoy es **template**: nombres, tamaños, versiones y región son
placeholders hasta tener los datos reales de la cuenta de DO (ver
"Antes de aplicar nada" más abajo).

```
terraform/
  bootstrap/        # crea el Space para el tfstate remoto — state local, se corre una vez
  modules/
    network/         # VPC propia
    doks/            # cluster DOKS + node pool con autoscale
    firewall/        # Cloud Firewall: solo 80/443 públicos hacia el futuro Ingress
    database/        # apunta (vía import) a la MySQL gestionada que ya existe
  environments/
    prod/            # único ambiente por ahora; wiring de los módulos + backend remoto
```

Un solo ambiente (`prod`) a propósito: los módulos están separados para
poder agregar `environments/staging` más adelante reusándolos tal cual,
sin reescribir nada de `modules/`.

## Antes de aplicar nada (bloqueado hasta tener la cuenta de DO a mano)

- **Región** real de la cuenta/proyecto.
- **Versión de Kubernetes vigente**: `doctl kubernetes options versions`.
  Poner el valor exacto en `doks_version` (o fijar `doks_version_prefix` a
  la minor deseada y dejar que el módulo resuelva la última patch).
- **Datos exactos del cluster MySQL existente** (`bitacoradigital-database-...`):
  `engine_version`, `size`, `region`, `node_count`, `private_network_uuid`.
  Ver `modules/database/README.md` para el comando `doctl databases get`
  exacto. Si estos valores no coinciden con el recurso real, el import no
  sale limpio.
- **Nombre del Space y su región**, para `bootstrap/terraform.tfvars`.
- **Spaces access keys** (panel de DO → API → Spaces Keys) para
  `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` del backend.

Nada de esto se puede completar todavía — hasta entonces, cualquier valor
en los `.tfvars.example` es un placeholder, no un dato real.

## Orden de trabajo

### 0. Bootstrap del bucket de state (una sola vez, antes que todo lo demás)

```sh
cd bootstrap
export DIGITALOCEAN_TOKEN=...
cp terraform.tfvars.example terraform.tfvars   # bucket_name/region reales
terraform init
terraform apply
```

Este `apply` corre con **state local** (a propósito — no puede depender
del backend remoto que él mismo crea) y no se vuelve a tocar después. Ver
`bootstrap/README.md`.

### 1. Backend y credenciales del ambiente

1. Copiar `environments/prod/backend.hcl.example` a `backend.hcl`
   (gitignored) con los outputs de `bootstrap` (`bucket_name`, `region`,
   `endpoint`).
2. Exportar `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (keys de Spaces,
   no de AWS) y `DIGITALOCEAN_TOKEN` en la shell — nunca en archivos del
   repo ni en el chat.
3. Copiar `environments/prod/terraform.tfvars.example` a
   `terraform.tfvars` (gitignored) y completar con los datos reales
   reunidos en el paso anterior.

### 2. Init

```sh
cd environments/prod
terraform init -backend-config=backend.hcl
```

### 3. Import de la base de datos — antes de crear nada nuevo

```sh
terraform import 'module.database.digitalocean_database_cluster.this' <database-cluster-id>
```

### 4. Plan — debe salir "No changes" para `module.database`

```sh
terraform plan
```

Si el plan propone cualquier cambio sobre `module.database.digitalocean_database_cluster.this`
(y en especial si dice "forces replacement"), **parar ahí**: significa que
alguna variable (`engine_version`, `size`, `region`, `node_count`,
`private_network_uuid`) no coincide con el recurso real. Corregir las
variables y volver a `plan` hasta que esa parte del plan quede limpia.
Network, doks y firewall sí van a aparecer como "to add" en este primer
plan — es esperado, todavía no existen.

### 5. Apply del resto

Recién con el plan de `module.database` en "No changes":

```sh
terraform apply
```

Esto crea la VPC, el cluster DOKS y el firewall, y deja la base de datos
tal como estaba (gestionada por Terraform, sin tocar su configuración).

### 6. Conectar kubectl y smoke test

```sh
# kubeconfig vía terraform output (alternativa a doctl):
terraform output -raw doks_kube_config_raw > /tmp/digsigna-prod.kubeconfig
export KUBECONFIG=/tmp/digsigna-prod.kubeconfig

# o, equivalente, vía doctl:
# doctl kubernetes cluster kubeconfig save <doks_cluster_id>

kubectl get nodes
kubectl get pods -A

# smoke test trivial: levantar un pod descartable y confirmar que corre
kubectl run smoke-test --image=nginx --restart=Never
kubectl wait --for=condition=Ready pod/smoke-test --timeout=60s
kubectl delete pod smoke-test
```

Si `kubectl get nodes` muestra los nodos `Ready` y el pod de smoke test
llega a `Running`, el cluster y el autoscaler/node pool están operativos.

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
- `modules/firewall` solo abre 80/443 públicos (para el futuro Ingress).
  Los 6 backends (hsm-service, certificate-service, signing-service,
  identification-service, verification-service, audit-service) nunca se
  exponen ahí — solo hablan entre sí dentro del cluster y hacia afuera vía
  api-gateway. El tráfico intra-cluster (pods, kube-proxy, health checks)
  se permite vía `source_kubernetes_ids`, acotado a este cluster DOKS
  puntual, no a todo Internet.
- Backend remoto en DO Spaces (S3-compatible) con locking nativo
  (`use_lockfile = true`, soportado desde Terraform 1.10) — sin necesitar
  DynamoDB. El bucket lo crea `bootstrap/`, separado y con state local,
  para evitar el problema de huevo-gallina de depender de su propio
  backend.
