# Inventario de variables de entorno / secrets — los 7 servicios

Tarea 1 del plan de `k8s/`: inventariar qué variable necesita cada servicio,
leyendo las fuentes reales de cada repo (`docker-compose.dev.yml`,
`.env.example`, el módulo de config real) — no se asumió nada. Esta es la
entrada para decidir, en una tarea separada, el mecanismo de carga de
Secrets/ConfigMaps en `k8s/` (ver `docs/plan.md` y `README.md` de este repo
para el patrón ya validado en `terraform/`: templates committeados sin
valores reales, valores reales en archivos gitignored).

No se escribió ningún manifiesto de Kubernetes todavía — eso es la tarea
siguiente, a propósito, después de que este inventario esté confirmado.

## 🔴 Hallazgo crítico, fuera del alcance de esta tarea pero urgente

`softhsm/k8s/migrations-job.yaml` (repo `softhsm`, commit `e9a16b8`, pusheado
a `github.com/DigSigna/softhsm`) tiene una credencial **real** de la MySQL
gestionada hardcodeada en texto plano:

```
mysql://digsigna:<REDACTADO-password-real-filtrado>@tcp(bitacoradigital-database-dec-26-backup-do-user-7050795-0.b.db.ondigitalocean.com:25060)/digsigna?tls=skip-verify
```

(Password real redactado de este documento -- GitHub push protection lo
detecta como credencial de Aiven aunque la base de datos de origen ya no
exista y el valor no sea funcional. El hallazgo en sí sigue documentado:
ver el commit de `softhsm` citado arriba si se necesita el valor exacto
para una auditoría.)

Se verificó el resto de los 7 repos (`.env.example`, `docker-compose.dev.yml`,
CI) — todos los demás valores son fake de dev (`digsigna:digsigna`,
`root:root`, `ci:ci`, `admin:admin`). Este es el único secreto real expuesto
encontrado. **Acción pendiente, fuera de esta tarea**: rotar el password de
ese usuario en DO y mover ese DSN a un Secret cuando se migre
`migrations-job.yaml` a `platform-infra/k8s/` (tarea 2).

## Mecanismo de auditoría (ya resuelto, confirmado en los 7 repos)

Todos los productores leen la misma variable `AUDIT_API_KEY` (sin prefijo de
servicio, a propósito, para poder montar un único Secret con dos nombres
distintos) y mandan el header `X-Service-API-Key` a `POST /api/v1/events`.
audit-service la valida con un set de variables `AUDIT_KEY_<SERVICIO>`,
construido dinámicamente escaneando el entorno por prefijo (no hay que tocar
código para agregar un productor nuevo).

**Productores confirmados hoy: 6, no 5.** `api-gateway` (repo
`gateway-service`) ya es un productor real — el plan original
("api-gateway todavía no existe") está desactualizado. audit-service ya
tiene `AUDIT_KEY_API_GATEWAY` wireado en su `docker-compose.dev.yml`, pero
**falta** en `docker-compose.debug.yml` del mismo repo, en
`docs/service-key-map.md` y en `scripts/generate-service-keys.sh` de este
repo (`platform-infra`) — pendiente para la tarea 2/3.

| Servicio productor | Secret k8s existente (`k8s/service-keys/`) | Estado |
|---|---|---|
| hsm-service | `hsm-service.secret.yaml` | shape OK |
| certificate-service | `certificate-service.secret.yaml` | shape OK |
| signing-service | `signing-service.secret.yaml` | shape OK |
| identification-service | `identification-service.secret.yaml` | shape OK |
| verification-service | `verification-service.secret.yaml` | shape OK (extensión ya unificada — RESUELTO en tarea 2) |
| api-gateway (`gateway-service`) | `gateway-service.secret.yaml` | shape OK (RESUELTO en tarea 2, ya tiene contenido real) |

`audit-service.secret.yaml` (en `k8s/service-keys/`) ya existe con forma
correcta: el lado receptor, con las 6 `AUDIT_KEY_<SERVICIO>` juntas —
RESUELTO en tarea 2 (ver `k8s/service-keys/audit-service.secret.yaml`).

## Service-to-service auth más allá de auditoría: no existe

Confirmado en certificate-service, signing-service y verification-service:
cuando llaman a hsm-service, certificate-service o identification-service
directamente, **reenvían el JWT del caller original tal cual** (`Authorization:
Bearer <token>` pass-through) — no hay ninguna API key estática de
servicio-a-servicio para esas llamadas, solo para auditoría. No hace falta
generar ningún Secret nuevo para esos tramos.

## Por servicio

### identification-service

| Variable | Tipo | Valor en dev | ¿Rotar antes de prod? |
|---|---|---|---|
| `DB_URL` | Secret | `mysql://digsigna:digsigna@tcp(mysql:3306)/digsigna?parseTime=true` | No rotar — es fake de dev. Generar credencial real de prod (usuario `digsigna_app` de `migrations/scripts/setup-db-users.sh`, no reusar el password de dev). |
| `KEYCLOAK_BASE_URL` | Config | `http://keycloak:8080` | — (no es secreto) |
| `KEYCLOAK_ADMIN_USER` | Config | `admin` | — |
| `KEYCLOAK_ADMIN_PASSWORD` | Secret | `admin` | No rotar — fake. Generar real antes de prod. Es contra `admin-cli`/realm `master`, no hay client_secret por realm (el login client es público, sin secret). |
| `BOOTSTRAP_SECRET` | Secret | `dev-bootstrap-secret` | No rotar — fake. Generar real antes de prod (protege `POST /api/v1/bootstrap`). |
| `AUDIT_API_KEY` | Secret | `dev-audit-shared-key-never-use-outside-dev` | Ya cubierto por el mecanismo de `generate-service-keys.sh`. |
| `JWT_SIGNING_KEYS_DIR` (par RSA) | Config (ruta) | generado en memoria si falta | RESUELTO: `k8s/storage/identification-service-jwt-keys-pvc.yaml` (PVC escribible, el proceso se auto-provisiona). **No usar `JWT_PRIVATE_KEY_PATH`/`JWT_PUBLIC_KEY_PATH`** — esas desactivan la rotación real que el código soporta (`signer.js`'s `rotate()` las rechaza explícitamente). Confirmado en una auditoría posterior que un primer intento (Secret + esas dos vars) sí las usaba por error — corregido. |
| `REDIS_URL` | Config/Secret | vacío (sin Redis en dev) | Diferible — rate limiter cae a memory store si falta. |
| `HSM_SERVICE_URL`, `CERTIFICATE_SERVICE_URL` | Config | URLs internas | No son secretos. |
| `IDEMPOTENCY_TTL_MS` | Config | sin default documentado (24h hardcoded) | Decidir si fijar explícito. |

### hsm-service

| Variable | Tipo | Valor en dev | ¿Rotar antes de prod? |
|---|---|---|---|
| `DATABASE_URL` | Secret | `digsigna:digsigna@tcp(mysql:3306)/digsigna?...` | No rotar — fake. Generar real. |
| `HSM_PIN` | Secret | `1234` | No rotar — fake, y el único PIN que lee el código (no existe un SO-PIN consumido por la app Go). Generar real antes de prod. |
| `HSM_LIBRARY_PATH`, `HSM_TOKEN_LABEL`, `HSM_SLOT` | Config | rutas/slot de SoftHSM | No secretos. |
| `HSM_AESKEYMANAGER_STRATEGY` | Config | `local` (dev) / `k8s` (prod, default) | — |
| `HSM_AESKEYMANAGER_LOCAL_MASTER_KEY` | Secret | `LLvxgXPJCEY1sek2eTNihV7laqAIVdQVxz11eYcA8oU=` | El código mismo rechaza este literal en producción (`log.Fatal` si coincide) — protección ya existe, no hace falta nada extra salvo generar una real para `k8s`. |
| `HSM_AESKEYMANAGER_K8S_SECRET_NAME` (default `hsm-secrets`) | Config | `hsm-secrets` | Coincide con el Secret `hsm-secrets` que se va a migrar en la tarea 2. |
| `HSM_AESKEYMANAGER_K8S_MASTER_KEY_KEY` (default `master-aes-key-v1`) | Config | — | **Verificar en tarea 2**: el Secret `hsm-secrets` actual (`softhsm/k8s/hsm-secrets.yaml`) ya tiene un campo `master-aes-key-v1` — coincide. Tiene además campos redundantes (`master-key`, `v1`, `master-key-id`) que ningún código confirmado lee hoy; limpiar al migrar salvo que se confirme otro consumidor. |
| `HSM_AESKEYMANAGER_K8S_OLD_MASTER_KEY_KEY` (default `master-key-old`) | Config | — | Coincide con el campo `master-key-old` ya presente en el Secret. |
| `AUDIT_API_KEY` | Secret | `dev-audit-shared-key-never-use-outside-dev` | Cubierto por `generate-service-keys.sh`. |

Nota: `docker-compose.debug.yml` de hsm-service parece obsoleto (usa
credenciales de DB distintas, depende de un `redis` que no existe en el
compose activo) — no usarlo como fuente de verdad.

### certificate-service

| Variable | Tipo | Valor en dev | ¿Rotar antes de prod? |
|---|---|---|---|
| `DB_URL` | Secret | `mysql://digsigna:digsigna@mysql:3306/digsigna` | No rotar — fake. Generar real. |
| `HSM_SERVICE_BASE_URL`, `IDENTITY_SERVICE_BASE_URL` | Config | URLs internas | No secretos — llamadas vía JWT pass-through, sin key propia. |
| `AUDIT_API_KEY` | Secret | `dev-audit-shared-key-never-use-outside-dev` | Cubierto por `generate-service-keys.sh`. |
| `AUTH_JWKS_URL` / `AUTH_ISSUER` / `AUTH_AUDIENCE` | Config | URL/strings | No secretos. RESUELTO: las 3 ya están en `k8s/manifests/certificate-service.secret.yaml` (`AUTH_ISSUER`/`AUTH_AUDIENCE` faltaban del manifiesto hasta una auditoría posterior, aunque ya estaban aquí documentadas). |
| `DIGSIGNA_COMMON_TOKEN` | Secret de **build-time**, no runtime | PAT de GitHub, exportado por quien construye la imagen | No va en ningún Secret de k8s del pod — es un secret de CI/build (BuildKit secret mount), fuera del alcance de `k8s/`. |

`HSM_LIBRARY_PATH`/`HSM_SLOT`/`HSM_PIN`/`HSM_TOKEN_LABEL` aparecen en
`.env.example` pero no tienen consumidor real en este repo (vestigio de un
backend PKCS11 directo ya reemplazado por la llamada HTTP a hsm-service) —
no migrar.

### signing-service

Mismo patrón que certificate-service: `DB_URL` (fake dev), `AUDIT_API_KEY`
(cubierta), `HSM_SERVICE_BASE_URL`/`CERTIFICATE_SERVICE_BASE_URL` (URLs,
JWT pass-through sin key propia), `DIGSIGNA_COMMON_TOKEN` (build-time, no
runtime). Específico de este servicio:

| Variable | Tipo | Valor en dev | Notas |
|---|---|---|---|
| `TSA_PRIMARY_URL` / `TSA_SECONDARY_URL` | Config | `https://freetsa.org/tsr` / `http://time.certum.pl` | Servicios públicos gratuitos, sin credenciales. |
| `REDIS_HOST`/`REDIS_PORT`/`REDIS_PASSWORD`/`REDIS_DB` | Config/Secret | sin valor en dev | **No es diferible como en verification-service**: `GET /health` llama `check_redis()` de forma incondicional (no depende de `AUTH_TOKEN_CACHE_ENABLED`) — sin esto, el healthcheck del pod siempre reporta `status: "degraded"`. Agregadas a `k8s/manifests/signing-service.secret.yaml`, pero falta decidir Redis dedicado vs. reusar `k8s/deployments/redis-gateway.yaml` (gap abierto, ver `k8s/README.md`). |

Mismas variables `HSM_*` muertas que certificate-service (vestigio PKCS11),
no migrar.

### verification-service

Mismo patrón: `DB_URL` (fake dev), `AUDIT_API_KEY` (cubierta),
`CERTIFICATE_SERVICE_BASE_URL` (URL pública sin auth — el cliente HTTP
explícitamente no manda ningún header de auth, por diseño, son endpoints
públicos de certificate-service). `REDIS_*` declaradas pero sin consumo real
hoy (solo si se habilita `AUTH_TOKEN_CACHE_ENABLED`, que está en `false`).

### api-gateway (repo `gateway-service`)

| Variable | Tipo | Valor en dev | ¿Rotar antes de prod? |
|---|---|---|---|
| `GATEWAY_AUTH_JWKS_URL` | Config | `http://identification-service:3000/.well-known/jwks.json` | No secreto. Gateway no habla con Keycloak directo, solo con el JWKS propio de identification-service. |
| `GATEWAY_REDIS_ADDRESS` | Config/Secret | `redis:6379` (sin AUTH, sin password) | RESUELTO: Redis real en `k8s/deployments/redis-gateway.yaml` (Service "redis"), variable fijada en `k8s/envs/gateway-service.env.example`. |
| `GATEWAY_CONFIG_PATH` / `GATEWAY_ENVIRONMENT` | Config | — (no existen en dev, CWD-relativo) | **Gap encontrado en auditoría posterior**: el Dockerfile de runtime no copia `config/` a la imagen (mismo patrón que hsm-service con `HSM_CONFIG_PATH`). RESUELTO: `k8s/configmaps/gateway-service-config.yaml` + estas dos vars en el Secret de env. `cors.allowed_origins` queda en placeholder hasta tener el dominio real del frontend. |
| `AUDIT_API_KEY` | Secret | `dev-audit-shared-key-never-use-outside-dev` | api-gateway ya es productor real (ver arriba). RESUELTO en tarea 2: `k8s/service-keys/gateway-service.secret.yaml` ya tiene contenido y su fila en `docs/service-key-map.md`. |

### audit-service

| Variable | Tipo | Valor en dev | Notas |
|---|---|---|---|
| `DATABASE_URL` | Secret | `digsigna:digsigna@tcp(mysql:3306)/digsigna?...` | No rotar — fake. Generar real. |
| `AUDIT_KEY_HSM_SERVICE`, `AUDIT_KEY_CERTIFICATE_SERVICE`, `AUDIT_KEY_SIGNING_SERVICE`, `AUDIT_KEY_IDENTIFICATION_SERVICE`, `AUDIT_KEY_VERIFICATION_SERVICE`, `AUDIT_KEY_API_GATEWAY` | Secret (6, no 5) | `dev-audit-shared-key-never-use-outside-dev` en las 6 | Mismo valor que el Secret `*-audit-key` de cada productor, montado con otro nombre de variable en el pod de audit-service. **`AUDIT_KEY_API_GATEWAY` es nueva, no documentada todavía.** |
| `AUDIT_AUTH_JWKS_URL` / `AUDIT_AUTH_MODE` | Config | — | Para validar JWT de endpoints de usuario final (no de ingestión), separado del mecanismo de arriba. |

## Variables confirmadas como muertas / sin efecto (no migrar esperando que funcionen)

- `AUDIT_AUTH_JWKS_CACHE_MINUTES` (audit-service) y `HSM_AUTH_JWKS_CACHE_MINUTES`
  (hsm-service): bindeadas en viper pero el código hardcodea `60` igual,
  ignorando la variable.
- `LOG_LEVEL` en varios repos (audit-service, hsm-service, signing-service):
  sin ningún consumidor confirmado en el código de ese repo.
- `HSM_LIBRARY_PATH`, `HSM_SLOT`, `HSM_PIN`, `HSM_TOKEN_LABEL`,
  `HSM_SESSION_TIMEOUT`, `HSM_MAX_SESSIONS` en certificate-service y
  signing-service: vestigio de un backend PKCS11 directo ya reemplazado por
  la llamada HTTP a hsm-service.
- `AUDIT_SERVICE_URL` en `.env.example` de hsm-service: nombre obsoleto, la
  variable real que lee el código es `HSM_AUDIT_HTTP_BASE_URL`.

## Secrets de build-time (fuera de alcance de `k8s/`, van en CI/registro de imágenes)

`DIGSIGNA_COMMON_TOKEN` (PAT de GitHub, read-only, para instalar
`go-common`/`py-common` como dependencia privada durante el build de la
imagen) aparece en hsm-service, audit-service, certificate-service,
signing-service y verification-service. Nunca llega al entorno de runtime
del contenedor — se monta como BuildKit secret o GitHub Actions secret
durante el build. No le corresponde un Secret de Kubernetes del pod; si
`platform-infra` llega a gestionar el pipeline de build, se trata aparte.

## Comentarios desactualizados encontrados (no bloquean nada, pero vale avisar)

En `docker-compose.dev.yml` de hsm-service, certificate-service,
signing-service, verification-service e identification-service hay
comentarios que dicen "`AUDIT_API_KEY` todavía sin consumidor en este
código" — desactualizados: los 5 (ahora 6, con api-gateway) ya la consumen
activamente para mandar eventos a audit-service.

## Resumen accionable para la tarea 2/3 — TODO completado, ver abajo

Checklist original de la tarea 1, dejado como registro histórico. Los 9
puntos ya se ejecutaron (tareas 2/3 + una auditoría posterior de los 6
repos restantes, ver `k8s/README.md` sección "Gaps conocidos"). El punto 6
se resolvió con PVC + auto-rotación del propio proceso, no con un Secret
estático (ver `k8s/storage/identification-service-jwt-keys-pvc.yaml` — un
Secret hubiera desactivado la rotación real que el código soporta).

1. Rotar el password real filtrado de la MySQL gestionada (hallazgo crítico,
   independiente de esta migración).
2. Completar `k8s/service-keys/gateway-service.secret.yaml` (vacío) con el
   mismo shape que los otros 5 productores.
3. Crear el Secret propio de audit-service con las 6 `AUDIT_KEY_<SERVICIO>`
   (no existe manifiesto hoy).
4. Agregar `api-gateway` a `scripts/generate-service-keys.sh` y a
   `docs/service-key-map.md` como 6to productor.
5. Unificar la extensión de `verification-service.secret.yml` a
   `.secret.yaml` para consistencia.
6. Decidir cómo persistir el par RSA de JWT de identification-service entre
   restarts de pod (Secret vs PVC).
7. Desplegar Redis (o apuntar a uno gestionado) y setear
   `GATEWAY_REDIS_ADDRESS` — ya no es diferible para api-gateway.
8. Migrar `hsm-secrets.yaml` y `migrations-job.yaml` desde `softhsm/k8s/` a
   `platform-infra/k8s/`, sacando el DSN real hardcodeado de
   `migrations-job.yaml` y reemplazándolo por una referencia a Secret.
9. Mantener los nombres de campo `master-aes-key-v1` y `master-key-old` en
   el Secret `hsm-secrets` migrado (son los que hsm-service realmente lee);
   confirmar si `master-key`/`v1`/`master-key-id` siguen teniendo algún
   consumidor antes de decidir si se limpian.
