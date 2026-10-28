# k8s/

Manifiestos de Kubernetes para los 7 servicios de DigSigna (api-gateway,
identification-service, hsm-service, certificate-service, signing-service,
verification-service, audit-service), todos sobre una sola MySQL compartida
(decisión ya tomada). Mismo patrón que `terraform/` de este repo: lo que se
commitea es la **estructura** (manifiestos `Secret` con keys pero sin
valores reales), los **valores reales viven en archivos gitignored**
(`k8s/envs/*.env`, análogo a `terraform.tfvars`), y se generan/aplican con
scripts, nunca escritos a mano en un YAML que se vaya a commitear.

Punto de partida de todo esto: `docs/env-vars-inventory.md` — el inventario
completo, servicio por servicio, de qué variable necesita cada uno, leído
directamente del código real de los 7 repos (no asumido). Léanlo antes de
tocar cualquier valor real.

**Fuera de alcance de este directorio, a propósito**: no hay ningún
`Deployment`/`Service`/`Ingress` todavía para ninguno de los 7 servicios —
esta ronda de trabajo cubrió solo el inventario de variables/secrets y su
mecanismo de carga (tareas 1-3 de `docs/plan.md`... ver el historial de
`docs/` de este repo). Tampoco hay un Redis desplegado (api-gateway ya lo
necesita de verdad para `/ready`, ver más abajo) ni manifiestos de RBAC —
eso sigue en `softhsm/k8s/` sin migrar (solo se migraron `hsm-secrets.yaml`
y `migrations-job.yaml`, que era el alcance de la tarea 2).

```
k8s/
  namespace.yaml              # namespace "digsigna", nada lo creaba todavía
  shared-secrets/             # Secrets compartidos entre varios servicios
    mysql-secrets.secret.yaml   # DSN de la MySQL gestionada (migrado de softhsm/k8s/)
    hsm-secrets.secret.yaml     # PIN/SO-PIN/master keys de SoftHSM (migrado de softhsm/k8s/)
  jobs/
    migrations-job.yaml         # migrado de softhsm/k8s/ -- ya no hardcodea el DSN
  manifests/                   # un Secret por servicio con SU config/secrets propios
    identification-service.secret.yaml
    identification-service-jwt-keys.secret.yaml  # par RSA de firma JWT (aparte, se monta como volumen)
    hsm-service.secret.yaml
    certificate-service.secret.yaml
    signing-service.secret.yaml
    verification-service.secret.yaml
    gateway-service.secret.yaml
    audit-service.secret.yaml
  service-keys/                # YA EXISTÍA: mecanismo de auth productor->audit-service
    <servicio>.secret.yaml       # una api_key por productor (incluye ahora gateway-service)
    audit-service.secret.yaml    # el lado receptor: las 6 AUDIT_KEY_<SERVICIO> juntas
  envs/                        # valores reales -- GITIGNORED salvo los .example
    <servicio>.env.example
```

## Los tres mecanismos de generación (no son intercambiables)

Hay tres tipos de secreto, cada uno con su propio generador, porque cada uno
tiene una forma distinta:

### 1. Config/secrets propios de cada servicio → `manifests/` + `envs/` + `apply-service-env-secrets.sh`

Para `DB_URL`, `KEYCLOAK_ADMIN_PASSWORD`, `BOOTSTRAP_SECRET`, URLs internas,
etc. — todo lo que es un simple `KEY=VALUE` por servicio.

```sh
cp k8s/envs/<servicio>.env.example k8s/envs/<servicio>.env   # completar con valores reales
scripts/apply-service-env-secrets.sh <servicio>              # o sin argumentos: los 7
```

Esto corre `kubectl create secret generic <servicio>-env --from-env-file=... --dry-run=client -o yaml | kubectl apply -f -`
— idempotente, rotar un valor es editar el `.env` y volver a correrlo.

### 2. API keys de auditoría (productor → audit-service) → `service-keys/` + `generate-service-keys.sh`

Ya existía antes de esta ronda de trabajo, sin cambios de mecanismo — solo
se le agregó `gateway-service` como 6to productor y se completó el Secret
propio de `audit-service` (que junta las 6 keys del lado receptor). Ver
`docs/service-key-map.md`.

```sh
scripts/generate-service-keys.sh                 # genera/rota las 6
```

El script imprime cada key generada una sola vez — copiarla a mano al
Secret `audit-service-producer-keys` (`k8s/service-keys/audit-service.secret.yaml`
es solo la referencia de shape, igual que los otros):

```sh
kubectl create secret generic audit-service-producer-keys \
  --from-literal=AUDIT_KEY_HSM_SERVICE=<key-de-hsm-service> \
  --from-literal=AUDIT_KEY_CERTIFICATE_SERVICE=<key-de-certificate-service> \
  --from-literal=AUDIT_KEY_SIGNING_SERVICE=<key-de-signing-service> \
  --from-literal=AUDIT_KEY_IDENTIFICATION_SERVICE=<key-de-identification-service> \
  --from-literal=AUDIT_KEY_VERIFICATION_SERVICE=<key-de-verification-service> \
  --from-literal=AUDIT_KEY_API_GATEWAY=<key-de-gateway-service> \
  -n digsigna --dry-run=client -o yaml | kubectl apply -f -
```

### 3. Pares de claves / secretos compartidos sin forma `KEY=VALUE` → scripts dedicados

- `mysql-secrets` (`connection_string` completo, con host/usuario/password
  de la MySQL gestionada): no hay script — se aplica a mano, porque esos
  valores vienen de DigitalOcean (ver `terraform/modules/database/`), no se
  generan localmente.

  ```sh
  kubectl create secret generic mysql-secrets \
    --from-literal=connection_string="mysql://usuario:password@tcp(host:3306)/digsigna?tls=true" \
    -n digsigna --dry-run=client -o yaml | kubectl apply -f -
  ```

- `hsm-secrets` (PIN, SO-PIN, master key AES): tampoco hay script todavía
  (generar un PIN/master key real es una decisión operativa, no algo para
  automatizar sin estar seguros del procedimiento de custodia) — aplicar a
  mano con `kubectl create secret generic hsm-secrets --from-literal=...`
  siguiendo los campos de `k8s/shared-secrets/hsm-secrets.secret.yaml`.

- `identification-service-jwt-keys` (par RSA de firma JWT):

  ```sh
  scripts/generate-identification-jwt-keys.sh
  ```

## Orden para aplicar todo desde cero

1. `kubectl apply -f k8s/namespace.yaml`
2. `mysql-secrets` y `hsm-secrets` (mecanismo 3, a mano — ver arriba)
3. `k8s/jobs/migrations-job.yaml` (depende de `mysql-secrets`)
4. `scripts/generate-service-keys.sh` + Secret `audit-service-producer-keys` a mano (mecanismo 2)
5. `scripts/generate-identification-jwt-keys.sh` (mecanismo 3)
6. `scripts/apply-service-env-secrets.sh` (mecanismo 1, los 7 servicios)

Ningún paso de arriba incluye desplegar los servicios en sí (no hay
`Deployment` todavía) — esto deja los Secrets listos para cuando esos
manifiestos se escriban.

## Gaps conocidos, señalados a propósito (no resueltos en esta ronda)

- **Redis para api-gateway**: `GATEWAY_REDIS_ADDRESS` queda vacía en
  `k8s/envs/gateway-service.env.example` porque no hay Redis desplegado
  todavía. Sin esto, `/ready` de api-gateway pasa el check de Redis
  trivialmente (cae a rate-limit en memoria) — no es un estado seguro para
  producción multi-réplica, ver `docs/env-vars-inventory.md`.
- **Campos vestigiales en `hsm-secrets`** (`master-key`, `v1`): se
  preservaron en la migración por no poder confirmar con certeza que nada
  los lee — candidatos a limpieza en una pasada futura.
- **RBAC/Deployments/ConfigMaps de hsm-service** (`hsm-service-rbac.yaml`,
  `hsm-sidecar-deployment.yaml`, `hsm-service-config.yaml`,
  `softhsm-*.yaml`, `auth-public-key-configmap.yaml`) siguen en
  `softhsm/k8s/` sin migrar — la tarea 2 solo pedía migrar
  `hsm-secrets.yaml` y `migrations-job.yaml`.
