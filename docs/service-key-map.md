# Mapa de API keys de servicio (productores -> audit-service)

Quién tiene qué key para autenticar `POST /api/v1/events` contra audit-service.
Nunca el valor crudo de la key -- sólo su fingerprint, para poder confirmar
"esta es la key vigente" sin exponerla. El valor real vive únicamente en el
Secret de Kubernetes (ver `k8s/service-keys/`) y en el gestor de secretos de
quien lo generó.

audit-service no aparece como fila: es quien valida estas keys, no quien
produce eventos. Si en el futuro necesita su propia credencial (p. ej. para
un endpoint administrativo), eso se trata aparte, no en esta tabla.

| Servicio | Secret en k8s | Namespace | Permiso otorgado | Fecha de generación | Fingerprint |
|---|---|---|---|---|---|
| hsm-service | `hsm-service-audit-key` | `digsigna` | `audit-service:events:write` | 2026-10-31T02:02:48Z | sha256:723fb0fd0363 |
| certificate-service | `certificate-service-audit-key` | `digsigna` | `audit-service:events:write` | 2026-10-31T02:02:48Z | sha256:d7ce51414201 |
| signing-service | `signing-service-audit-key` | `digsigna` | `audit-service:events:write` | 2026-10-31T02:02:48Z | sha256:af8e19752571 |
| identification-service | `identification-service-audit-key` | `digsigna` | `audit-service:events:write` | 2026-10-31T02:02:48Z | sha256:9f29881a9f5e |
| verification-service | `verification-service-audit-key` | `digsigna` | `audit-service:events:write` | 2026-10-31T02:02:48Z | sha256:006c023dafee |
| api-gateway (repo `gateway-service`) | `gateway-service-audit-key` | `digsigna` | `audit-service:events:write` | 2026-10-31T02:02:48Z | sha256:43300256734b |

`verification-service` no estaba en la lista original del plan, pero ya usa
el mismo wiring de py-common/audit hybrid que certificate-service y
signing-service (`AUDIT_ENABLED`/`AUDIT_STRATEGY` en `config.py` y
`docker-compose.dev.yml`) -- es un productor real hoy, así que se incluyó
acá con el mismo tratamiento que los otros 4.

`api-gateway` tampoco estaba en la lista original ("todavía no existe");
confirmado leyendo el código real del repo `gateway-service` que ya es
productor (manda `X-Service-API-Key` a audit-service en rechazos de JWT y
bloqueos de rate-limit) -- ver `docs/env-vars-inventory.md`. audit-service
ya tiene `AUDIT_KEY_API_GATEWAY` wireado en su `docker-compose.dev.yml`.

Al rotar una key (correr el script de nuevo para un servicio), actualizar a
mano la fila correspondiente con la fecha y el fingerprint que el script
imprime en ese momento -- el script no edita este archivo.

En producción, cada servicio productor monta el valor de su propio Secret
(`api_key`) como la variable de entorno `AUDIT_API_KEY`, y go-common/
py-common/el cliente JS de identification-service la mandan en el header
`X-Service-API-Key` de cada request a `POST /api/v1/events` (ver
docs/audit-clients-update.md). No se encontró todavía manifiesto de
despliegue de producción para ninguno de los 5 servicios en este repo ni en
los suyos propios -- montar ese Secret ahí queda pendiente hasta que ese
manifiesto exista.

audit-service, del lado receptor, valida esa misma key con
`ServiceKeyAuthMiddleware` (ver docs/audit-sservice-update.md) -- pero la lee
de *su propio* set de variables de entorno, una por productor conocido, no de
`AUDIT_API_KEY`: `AUDIT_KEY_HSM_SERVICE`, `AUDIT_KEY_CERTIFICATE_SERVICE`,
`AUDIT_KEY_SIGNING_SERVICE`, `AUDIT_KEY_IDENTIFICATION_SERVICE`,
`AUDIT_KEY_VERIFICATION_SERVICE`, `AUDIT_KEY_API_GATEWAY`. Es el mismo valor
que el Secret de la tabla de arriba montado dos veces con dos nombres de
variable distintos (uno en el pod del productor, otro en el pod de
audit-service) -- nunca un Secret/key nuevo. Sin esto configurado del lado
de audit-service (al menos uno), el proceso falla al arrancar en
producción. Agregar un productor nuevo del lado de audit-service es sólo
una variable de entorno más (`AUDIT_KEY_<SERVICIO>`), sin tocar código (ver
loadServiceKeys en audit-service/internal/infrastructure/config/app_config.go).
El manifiesto `k8s/service-keys/audit-service.secret.yaml` junta estas 6
variables en un solo Secret del lado de audit-service -- ver ese archivo y
`k8s/README.md`.

## Dev (no productivo)

En dev, los 5 productores comparten una única key fake estática vía
`AUDIT_API_KEY` en el `docker-compose.dev.yml` de cada repo. Ver README.md de
este repo, sección "Dev: key compartida" -- ese valor nunca debe salir de un
entorno de un solo host y nunca debe tratarse como las keys de esta tabla.
