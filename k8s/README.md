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

**Ya no fuera de alcance**: los 6 servicios de aplicación
(identification-service, certificate-service, signing-service,
verification-service, gateway-service, audit-service) ya tienen
`Deployment`+`Service` propios (ver `deployments/` abajo), y hay un
`Ingress` apuntando al único de los 6 que corresponde exponer
(gateway-service) -- ver `ingress/` abajo y
`terraform/modules/firewall/README.md` para la regla de diseño que esto
implementa (solo 80/443 públicos, siempre hacia gateway-service, nunca a
los otros 5 backends directo).

```
k8s/
  namespace.yaml              # namespace "digsigna", nada lo creaba todavía
  rbac/
    hsm-service-rbac.yaml       # migrado de softhsm/k8s/ -- ServiceAccount+Role+RoleBinding
  configmaps/
    hsm-service-config.yaml     # migrado de softhsm/k8s/ -- config.yaml de hsm-service
    softhsm-config.yaml         # migrado de softhsm/k8s/softhsm-configmap.yaml
    auth-public-key-configmap.yaml  # migrado de softhsm/k8s/ -- clave pública, SIN consumidor real hoy (auth es solo JWKS)
    gateway-service-config.yaml  # NUEVO -- copia fiel de gateway-service/config/config.production.yaml, resuelve el mismo gap de ruta de config que hsm-service tenía
    audit-service-config.yaml    # NUEVO -- mismo gap, copia fiel de audit-service/config/config.production.yaml
  storage/
    softhsm-pvc.yaml             # migrado de softhsm/k8s/ -- tokens de SoftHSM
    identification-service-jwt-keys-pvc.yaml  # NUEVO -- reemplaza el Secret de JWT, ver nota abajo
  deployments/
    hsm-service.yaml             # migrado y corregido contra docker-compose.dev.yml/código real -- sin initContainer de auto-init, auth vía JWKS production
    redis-gateway.yaml            # NUEVO -- Redis real para /ready de api-gateway (Service "redis"), reusado también por signing/verification-service
    keycloak.yaml                  # NUEVO -- Deployment+Service, `start` (no start-dev) contra MySQL, sin keycloak-seed (ver el archivo)
    identification-service.yaml    # NUEVO -- primero en el orden, sin dependencias de arranque
    certificate-service.yaml       # NUEVO
    audit-service.yaml             # NUEVO -- AUDIT_CONFIG_PATH + ConfigMap propio (gap nuevo encontrado, ver el archivo)
    signing-service.yaml           # NUEVO -- AUTH_ISSUER/AUTH_AUDIENCE + REDIS_* (gaps nuevos, ver el archivo)
    verification-service.yaml      # NUEVO -- mismos dos gaps que signing-service
    gateway-service.yaml           # NUEVO -- último en el orden, único backend de ingress/gateway-ingress.yaml
  ingress/
    gateway-ingress.yaml           # NUEVO -- único Ingress de este repo, solo gateway-service de backend (ver el archivo para las 3 decisiones que resuelve)
  shared-secrets/             # Secrets compartidos entre varios servicios
    mysql-secrets.secret.yaml   # DSN de la MySQL gestionada (migrado de softhsm/k8s/)
    hsm-secrets.secret.yaml     # PIN/SO-PIN/master keys de SoftHSM (migrado de softhsm/k8s/)
    keycloak-secrets.secret.yaml # NUEVO -- admin bootstrap + credenciales del esquema "keycloak" propio en la misma MySQL
  jobs/
    migrations-job.yaml         # migrado de softhsm/k8s/ -- ya no hardcodea el DSN, y corregido contra el ENTRYPOINT real de la imagen
  manifests/                   # un Secret por servicio con SU config/secrets propios
    identification-service.secret.yaml  # incluye JWT_SIGNING_KEYS_DIR -- ver storage/identification-service-jwt-keys-pvc.yaml
    hsm-service.secret.yaml
    certificate-service.secret.yaml   # incluye AUTH_ISSUER/AUTH_AUDIENCE
    signing-service.secret.yaml       # incluye REDIS_* -- resuelto, reusa deployments/redis-gateway.yaml
    verification-service.secret.yaml  # incluye REDIS_* (gap nuevo encontrado) y AUTH_ISSUER/AUTH_AUDIENCE va directo en el Deployment
    gateway-service.secret.yaml   # GATEWAY_REDIS_ADDRESS=redis:6379, GATEWAY_CONFIG_PATH -- ver configmaps/gateway-service-config.yaml
    audit-service.secret.yaml     # ya NO incluye AUDIT_AUTH_PUBLIC_KEY_PATH (dead en modo production, ver el archivo)
  service-keys/                # YA EXISTÍA: mecanismo de auth productor->audit-service
    <servicio>.secret.yaml       # una api_key por productor (incluye ahora gateway-service)
    audit-service.secret.yaml    # el lado receptor: las 6 AUDIT_KEY_<SERVICIO> juntas
  envs/                        # valores reales -- GITIGNORED salvo los .example
    <servicio>.env.example
```

## Pre-requisito nuevo, encontrado al migrar: `ghcr-creds`

`k8s/jobs/migrations-job.yaml` y ahora `k8s/deployments/hsm-service.yaml`
referencian `imagePullSecrets: [{name: ghcr-creds}]` — ningún Secret con
ese nombre existe en este repo ni estaba documentado (se migró el Job sin
notarlo en la ronda anterior). Es un `docker-registry` Secret, no un
`Opaque` de `KEY=VALUE`, así que no tiene una forma de "shape sin valores"
útil para commitear — se crea a mano, igual criterio operativo que
`mysql-secrets`/`hsm-secrets`:

```sh
kubectl create secret docker-registry ghcr-creds \
  --docker-server=ghcr.io \
  --docker-username=<usuario-github> \
  --docker-password=<PAT-con-scope-read:packages> \
  --docker-email=<email> \
  -n digsigna
```

## Pre-requisito nuevo, encontrado al agregar Keycloak: imagen propia + esquema de MySQL

`k8s/deployments/keycloak.yaml` (NUEVO -- ver ese archivo para las tres
decisiones de diseño resueltas) necesita, antes de aplicarse:

1. Construir y pushear `ghcr.io/digsigna/keycloak:22.0.0-mysql` desde
   `images/keycloak/Dockerfile` (nuevo directorio, sin pipeline de CI
   todavía -- manual, igual criterio que `ghcr-creds`). La imagen pública
   `quay.io/keycloak/keycloak:22.0.0` que usa dev no trae el driver JDBC de
   MySQL (licencia GPL) -- hace falta una imagen propia con `kc.sh build
   --db=mysql`, ver el Dockerfile para el detalle completo.
2. Crear a mano, en la misma instancia de MySQL gestionada que ya usa
   `mysql-secrets`, un esquema `keycloak` propio (no el `digsigna`
   compartido) + un usuario con privilegios ahí -- `migrations/scripts/
   setup-db-users.sh` no lo cubre, sus GRANT son todos sobre `digsigna.*`.
   Ver el comentario de cabecera de `k8s/shared-secrets/keycloak-secrets.secret.yaml`
   para el SQL exacto.
3. Aplicar el Secret `keycloak-secrets` (mecanismo 3, a mano) -- su
   `admin-password` debe copiarse también a
   `KEYCLOAK_ADMIN_PASSWORD` del `.env` de identification-service: son el
   mismo admin-cli, en dos Secrets distintos.

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

- `identification-service-jwt-keys`: YA NO es un Secret generado por
  script — ver `k8s/storage/identification-service-jwt-keys-pvc.yaml`.
  Es un PVC vacío; el propio proceso de identification-service genera y
  persiste su par RSA ahí solo, la primera vez que arranca sin nada
  persistido (`loadOrGenerateKeyPair()` en `signer.js`). Solo hace falta
  `kubectl apply -f k8s/storage/identification-service-jwt-keys-pvc.yaml`
  antes de desplegar el servicio -- nada que generar a mano.

## Orden para aplicar todo desde cero

1. `kubectl apply -f k8s/namespace.yaml`
2. `ghcr-creds` a mano (ver pre-requisito arriba) — hace falta antes de
   `migrations-job.yaml`, `deployments/hsm-service.yaml` y
   `deployments/keycloak.yaml` (las tres imágenes viven en ghcr.io)
3. `mysql-secrets`, `hsm-secrets` y `keycloak-secrets` (mecanismo 3, a mano
   — ver arriba). Para `keycloak-secrets`: el esquema `keycloak` + su
   usuario ya tienen que existir en la MySQL gestionada antes (ver su
   comentario de cabecera), y construir/pushear
   `ghcr.io/digsigna/keycloak:22.0.0-mysql` (ver pre-requisito arriba)
4. `k8s/jobs/migrations-job.yaml` (depende de `mysql-secrets` y `ghcr-creds`)
5. `scripts/generate-service-keys.sh` + Secret `audit-service-producer-keys` a mano (mecanismo 2)
6. `kubectl apply -f k8s/storage/identification-service-jwt-keys-pvc.yaml` (mecanismo 3 -- PVC vacío, sin generación a mano)
7. `scripts/apply-service-env-secrets.sh` (mecanismo 1, los 7 servicios)
8. `kubectl apply -f k8s/rbac/hsm-service-rbac.yaml -f k8s/configmaps/ -f k8s/storage/softhsm-pvc.yaml`
9. `kubectl apply -f k8s/deployments/redis-gateway.yaml -f k8s/deployments/hsm-service.yaml -f k8s/deployments/keycloak.yaml`

Los pasos 8-9 cubren hsm-service (porque ya existía como manifiesto real
migrado), el Redis de apoyo de api-gateway (porque era un gap bloqueante
para `/ready`, y ahora también reusado por signing/verification-service)
y Keycloak (gap bloqueante para que identification-service pueda loguear
a nadie). Ninguno de los tres depende de los otros dos al arrancar
(hsm-service depende de identification-service, no de Keycloak
directamente -- ver el comentario de ordering en
`k8s/deployments/keycloak.yaml`), así que el orden entre ellos en este
paso no importa.

10. Los 6 `Deployment`/`Service` de los servicios de aplicación, en el
    orden sugerido por sus dependencias de arranque reales (confirmado
    leyendo `go-common/auth/key_manager.go` y
    `py_common/auth/key_manager_adapter.py`: los 5 restantes hacen un
    fetch SÍNCRONO de JWKS contra identification-service en el
    constructor, sin fallback -- igual que hsm-service):
    ```sh
    kubectl apply -f k8s/deployments/identification-service.yaml
    kubectl apply -f k8s/deployments/certificate-service.yaml -f k8s/deployments/audit-service.yaml
    kubectl apply -f k8s/deployments/signing-service.yaml -f k8s/deployments/verification-service.yaml
    kubectl apply -f k8s/deployments/gateway-service.yaml
    ```
    Como con hsm-service/keycloak, ninguno usa un `initContainer` de
    espera -- si identification-service todavía no respondió cuando un
    pod arranca, ese pod crashea y Kubernetes lo reintenta solo
    (`CrashLoopBackOff` normal), mismo criterio ya establecido. El orden
    entre certificate-service/audit-service y entre signing-service/
    verification-service no importa al arrancar (ninguno depende del
    otro) -- es solo una sugerencia de secuencia, no una dependencia dura.
    gateway-service al final porque es el único que el Ingress expone, y
    sus propios `/health`/`/ready` no dependen de los otros 5 para
    responder (solo sus endpoints de health agregado, que no son los que
    usan las probes de este Deployment).
11. Instalar ingress-nginx (Helm, fuera de este repo -- ver el comentario
    de cabecera de `k8s/ingress/gateway-ingress.yaml`) y luego
    `kubectl apply -f k8s/ingress/gateway-ingress.yaml`.

## Gaps conocidos, señalados a propósito

**Resueltos en esta ronda:**

- **Redis para api-gateway**: resuelto, ver `k8s/deployments/redis-gateway.yaml`
  y `GATEWAY_REDIS_ADDRESS=redis:6379` en `k8s/envs/gateway-service.env.example`.
- **RBAC/Deployments/ConfigMaps de hsm-service**: migrados de
  `softhsm/k8s/` a `k8s/rbac/`, `k8s/configmaps/`, `k8s/storage/` y
  `k8s/deployments/` (ver árbol arriba). Los archivos originales siguen
  además en `softhsm/k8s/` sin tocar — es otro repo, no se borró nada ahí.
- **Desface de información corregido** (ver también los comentarios de
  cabecera de `k8s/deployments/hsm-service.yaml` y
  `k8s/shared-secrets/hsm-secrets.secret.yaml`): la primera migración de
  hsm-service se basó en `softhsm/k8s/`, que quedó congelado en un estado
  anterior de la arquitectura real. Releyendo
  `hsm-service/docker-compose.dev.yml` y el código real (no asumido) se
  corrigió:
  - Se quitó el `initContainer` que auto-inicializaba un token al
    arrancar — la arquitectura real ya no hace esto, cada tenant
    (incluido root) provisiona su propio slot vía
    `POST /internal/hsm/slots/initialize`.
  - `so-pin` pasó de "confirmado en uso" a vestigial — no hay ningún
    SO-PIN en el código Go de hsm-service, solo lo usaba el script viejo
    que el initContainer ya no corre.
  - `HSM_AUTH_MODE` → `"production"` (no `"development"`) y
    `HSM_AUTH_JWKS_URL` → `identification-service` (no `localhost`) —
    confirmado que el dev-compose real ya corre en modo production.
  - Se sacó `HSM_AUTH_PUBLIC_KEY_PATH` y el volumen de
    `auth-public-key-configmap.yaml` del Deployment — sin consumidor real
    con auth vía JWKS.
  - Se sacó `DATABASE_ENABLED` — no es un campo real, dead config.
  - Se agregó `HSM_CONFIG_PATH` (y se corrigió la ruta de montaje del
    ConfigMap) — sin esto, el proceso no encuentra ningún archivo de
    config al arrancar (incidente real, documentado en el propio código
    de hsm-service).
  - Se agregó `AUDIT_API_KEY` (faltaba por completo) — sin esto
    hsm-service no puede autenticarse contra audit-service.
  - El ConfigMap `hsm-service-config.yaml` ahora es una copia fiel de
    `hsm-service/config/config.production.yaml` en vez de una versión
    reconstruida a mano con nombres de campo y valores desactualizados
    (`master_key_key`, `max_sessions`, PIN de dev commiteado, etc.)
  - `k8s/jobs/migrations-job.yaml` invocaba la imagen mal -- leía una
    variable (`MYSQL_DSN`) que `migrations/scripts/migrate.sh` (el
    `ENTRYPOINT` real de `ghcr.io/digsigna/migrations`) nunca lee, espera
    `DATABASE_URL`. Confirmado contra `hsm-service/docker-compose.dev.yml`
    (que usa `DATABASE_URL` + `command: up`) y corregido para no
    sobreescribir el `ENTRYPOINT`. También se pineó el tag (`:latest` →
    `1.0.75`, mismo tag que usa dev) por la misma razón que ya está
    documentada en ese docker-compose (Docker no re-pulea `:latest`
    automáticamente, ya causó un incidente real).

**Sobre "el slot del tenant root" (contexto, no un gap en sí)**: el repo
`migrations` tiene `scripts/setup-hsm-slot-seed.sh`, que asigna el tenant
más antiguo (el tenant plataforma raíz que siembra `setup-seed-dev.sh`) a
un slot de HSM -- pero solo escribe filas en MySQL (`hsm_slots`,
`aes_key_metadata`, `tenants.hsm_slot_id`), nunca toca SoftHSM/PKCS#11
directamente. Es un script interactivo aparte (pide confirmación explícita
en producción), no algo para automatizar en un Job sin que se pida --
no se wireó a ningún manifiesto de este repo a propósito.

**Resueltos tras auditar los 6 repos restantes** (certificate-service,
signing-service, verification-service, identification-service,
gateway-service, audit-service — mismo ejercicio que destapó el bug de
hsm-service, vía 6 agentes en paralelo releyendo `docker-compose.dev.yml`
+ código real de cada uno):

- **identification-service: el plan de JWT mataba la rotación real** (el
  mismo tipo de bug que hsm-service). `src/infrastructure/jwt/signer.js`
  tiene dos modos excluyentes: con `JWT_PRIVATE_KEY_PATH` seteada,
  `rotate()` tira error explícito ("not supported when
  JWT_PRIVATE_KEY_PATH is set"); sin ella pero con `JWT_SIGNING_KEYS_DIR`,
  el proceso genera y persiste su propio par, con rotación real (múltiples
  llaves activas por kid). El plan anterior (Secret +
  `JWT_PRIVATE_KEY_PATH`/`JWT_PUBLIC_KEY_PATH`) activaba el modo SIN
  rotación. Reemplazado: `k8s/storage/identification-service-jwt-keys-pvc.yaml`
  (PVC vacío, escribible) + `JWT_SIGNING_KEYS_DIR` en el Secret de env —
  el proceso se auto-provisiona la primera vez, sin script.
- **certificate-service: faltaban `AUTH_ISSUER`/`AUTH_AUDIENCE`** — sin
  ellas, `JWTValidatorAdapter` (py-common) valida cualquier issuer/
  audience, más laxo que en dev. Agregadas a
  `k8s/manifests/certificate-service.secret.yaml` y al `.env.example`.
- **gateway-service: mismo gap de `*_CONFIG_PATH` que hsm-service** — el
  Dockerfile de runtime no copia `config/` a la imagen. Agregado
  `k8s/configmaps/gateway-service-config.yaml` (copia fiel de
  `gateway-service/config/config.production.yaml`, con
  `cors.allowed_origins` en placeholder) + `GATEWAY_CONFIG_PATH`/
  `GATEWAY_ENVIRONMENT=production` en el Secret de env.

**Resuelto en una ronda posterior:**

- **Keycloak ya tiene Deployment+Service**: `k8s/deployments/keycloak.yaml`
  (NUEVO), con tres decisiones de diseño que no se podían copiar tal cual
  de dev — ver el comentario de cabecera de ese archivo para el detalle
  completo: (1) `start` en vez de `start-dev` (H2 embebido no persistente,
  inaceptable para prod) contra un esquema MySQL propio
  (`keycloak-secrets.secret.yaml`); (2) imagen propia
  (`ghcr.io/digsigna/keycloak:22.0.0-mysql`, `images/keycloak/Dockerfile`)
  porque la imagen base no trae el driver JDBC de MySQL (licencia GPL);
  (3) `keycloak-seed` (el parche de dev para el tenant raíz insertado
  directo en MySQL) NO se migra -- confirmado contra
  `create-tenant.js`/`bootstrap-platform.js` que el flujo real
  (`POST /bootstrap`) ya crea el realm como parte del mismo request, sin
  ningún hueco que parchar después.
- **`k8s/deployments/softhsm-standalone.yaml` — borrado**: confirmado con
  el equipo que era solo la prueba funcional manual de SoftHSM al migrarlo
  desde `softhsm/k8s/`, sin relación con la arquitectura real de
  hsm-service (que ya corre su propio SoftHSM como sidecar) y sin ningún
  otro manifiesto de este repo que lo referenciara. Ya no existe en este
  repo (antes solo estaba flaggeado, no incluido en el orden de
  aplicación).
- **"Drift de versión de la imagen `migrations` entre repos" — no era un
  drift**: era comparar contra el archivo equivocado.
  `certificate-service/docker-compose.yml`,
  `signing-service/docker-compose.yml` y
  `verification-service/docker-compose.yml` (que pinean `1.0.65`) son cada
  uno un compose "standalone" explícitamente aislado — su propia MySQL
  descartable, para correr ese servicio solo con `HSM_BACKEND=in_memory`,
  nunca contra el esquema compartido (ver el comentario de cabecera de
  cualquiera de los tres). No son la fuente real de ese tag en ningún
  entorno integrado. `k8s/jobs/migrations-job.yaml` pineando `1.0.75` sí
  coincide con `hsm-service/docker-compose.dev.yml` (el que gobierna el
  flujo real de una sola MySQL compartida, con el historial real de bump
  `1.0.72` → `1.0.73` por la migración `027_rbac_catalog_v1` documentado
  ahí) — ese es el valor correcto, nada que cambiar. Re-auditado
  específicamente contra `certificate-service/docker-compose.dev.yml` y
  `verification-service/docker-compose.dev.yml` (los composes reales, no
  los standalone) para confirmar que el resto del inventario de
  `docs/env-vars-inventory.md` para esos dos servicios también viene de
  ahí y no de ningún compose aislado -- coincide en ambos.

**Resuelto: los 6 `Deployment`/`Service` de servicios de aplicación +
Ingress** (lo que quedaba explícitamente fuera de alcance desde la
primera ronda):

- `k8s/deployments/{identification,certificate,signing,verification,audit,gateway}-service.yaml`
  + `k8s/ingress/gateway-ingress.yaml` -- ver el árbol arriba y el
  comentario de cabecera de cada archivo para el detalle completo. Orden
  sugerido documentado en "Orden para aplicar todo desde cero" arriba,
  basado en las dependencias de arranque reales (confirmadas leyendo
  código, no el plan sugerido a ciegas): identification-service primero
  (sin dependencias), los otros 5 dependen de él (fetch síncrono de JWKS
  al boot, sin fallback -- mismo patrón que hsm-service, confirmado en
  `go-common/auth/key_manager.go` y `py_common/auth/key_manager_adapter.py`),
  gateway-service al final (único expuesto por el Ingress).
- **Gap nuevo en audit-service**: `AUDIT_CONFIG_PATH` faltaba por
  completo -- mismo patrón ya corregido para hsm-service/gateway-service
  (Dockerfile Go multi-stage, no copia `config/` al runtime). Resuelto con
  `k8s/configmaps/audit-service-config.yaml` (NUEVO, copia fiel de
  `config.production.yaml`) + la variable en el Deployment.
- **`AUDIT_AUTH_PUBLIC_KEY_PATH` de audit-service — dead en producción**:
  estaba en `k8s/manifests/audit-service.secret.yaml` desde la ronda
  anterior, pero `go-common/auth/key_manager.go`'s `loadInitialKeys()`
  solo la lee en modo `development` -- en `production` usa JWKS
  exclusivamente (mismo patrón que `HSM_AUTH_PUBLIC_KEY_PATH`, ya
  corregido para hsm-service). Quitada de ese Secret y de
  `k8s/envs/audit-service.env.example`.
- **`AUTH_ISSUER`/`AUTH_AUDIENCE` también faltaban en signing-service y
  verification-service** -- el mismo gap que ya se había corregido solo
  para certificate-service, confirmado ahora también en estos dos
  (`issuer=settings.AUTH_ISSUER or None` en su `main.py`, default vacío en
  `config.py`: sin fijarla, acepta cualquier issuer/audience). Fijadas
  como constantes literales directo en cada Deployment (no son secretos).
- **Redis de signing-service/verification-service — resuelto**: reusa
  `k8s/deployments/redis-gateway.yaml` (Service `redis`) en vez de un
  Redis dedicado -- ambos solo hacen `PING` para su propio `/health`
  (nunca escriben ninguna key), así que compartirlo con api-gateway no
  tiene riesgo de colisión real. De paso se confirmó que
  verification-service tiene el MISMO gap que ya se había encontrado para
  signing-service: `app/interfaces/routes/health.py` es el mismo archivo
  (py_common) en los tres servicios, así que `GET /api/v1/health` llama
  `check_redis()` de forma incondicional también ahí -- el inventario
  original decía que era condicional a `AUTH_TOKEN_CACHE_ENABLED`, pero
  eso solo es cierto para el uso funcional (cache de validación de JWT),
  no para el healthcheck. Agregado a
  `k8s/manifests/verification-service.secret.yaml`/`.env.example`, que no
  tenían ningún campo `REDIS_*` hasta ahora.
- **Ingress Controller**: `ingressClassName: nginx` (ingress-nginx), no
  instalado por este repo (Helm release, fuera de alcance, mismo criterio
  que `terraform/modules/firewall/README.md` ya adelantaba). Sin
  `tls:`/dominio todavía -- mismo estado "placeholder" que
  `cors.allowed_origins` en `gateway-service-config.yaml`. Ver el
  comentario de cabecera de `k8s/ingress/gateway-ingress.yaml`.

**Sin resolver, señalados a propósito:**

- **PVC de `identification-service-jwt-keys` es `ReadWriteOnce`**: solo un
  pod puede montarlo a la vez — si identification-service necesita más de
  una réplica, esto es un cuello de botella real (no resuelto; depende de
  si `do-block-storage` en DOKS soporta `ReadWriteMany`, que normalmente
  no soporta para volúmenes de bloque).
- **NodePort range para el Load Balancer de DigitalOcean**: según cómo
  exponga el Service el Helm release de ingress-nginx todavía sin
  instalar (`type: LoadBalancer` con `externalTrafficPolicy`, NodePort, o
  `hostNetwork`), puede hacer falta abrir el rango de NodePort
  (30000-32767 por default) en `terraform/modules/firewall` además de
  80/443 -- se confirma recién cuando se instale el controller, ya
  señalado en `terraform/modules/firewall/README.md` y repetido en
  `k8s/ingress/gateway-ingress.yaml`.
- **Campos vestigiales en `hsm-secrets`** (`master-key`, `v1`, y ahora
  también `so-pin`): se preservan en la migración por no poder descartar
  con 100% de certeza que nada los lea fuera de este repo — candidatos a
  limpieza en una pasada futura.
- **`ghcr-creds`** (pull secret de GHCR): pre-requisito nuevo encontrado al
  migrar, ver sección arriba — se crea a mano, no hay script.
- **`softhsm/Dockerfile` (repo softhsm) sigue empaquetando el script
  viejo** (`softhsm/k8s/init-token-if-empty.sh`, con la lógica de
  auto-init que ya no se usa) en la imagen `ghcr.io/digsigna/softhsm/softhsm:1.0.0`.
  No afecta a este Deployment (ya no se invoca ese script), pero es un gap
  real en otro repo que vale la pena señalar al equipo de softhsm.
- **Imagen de los 6 Deployments nuevos: placeholder `REPLACE_VERSION`**
  (`ghcr.io/digsigna/<servicio>:REPLACE_VERSION`) -- el CI de cada repo
  tagea `1.0.${run_number}` + `latest` (ver su `.github/workflows/ci.yml`),
  pero ese número cambia con cada build y no hay forma de confirmarlo
  desde este repo sin acceso a GHCR/Actions. Reemplazar por el tag real
  antes de aplicar cada Deployment -- nunca dejar `latest` (mismo criterio
  ya documentado para `migrations-job.yaml`/`hsm-service.yaml`: un
  incidente real con un tag no re-pulleado).
