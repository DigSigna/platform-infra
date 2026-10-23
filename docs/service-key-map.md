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
| hsm-service | `hsm-service-audit-key` | `digsigna` | `audit-service:events:write` | _pendiente -- correr `scripts/generate-service-keys.sh`_ | _pendiente_ |
| certificate-service | `certificate-service-audit-key` | `digsigna` | `audit-service:events:write` | _pendiente -- correr `scripts/generate-service-keys.sh`_ | _pendiente_ |
| signing-service | `signing-service-audit-key` | `digsigna` | `audit-service:events:write` | _pendiente -- correr `scripts/generate-service-keys.sh`_ | _pendiente_ |
| identification-service | `identification-service-audit-key` | `digsigna` | `audit-service:events:write` | _pendiente -- correr `scripts/generate-service-keys.sh`_ | _pendiente_ |
| api-gateway | _(no existe todavía)_ | -- | -- | -- | -- |

Al rotar una key (correr el script de nuevo para un servicio), actualizar a
mano la fila correspondiente con la fecha y el fingerprint que el script
imprime en ese momento -- el script no edita este archivo.

## Dev (no productivo)

En dev, los 4 productores comparten una única key fake estática vía
`AUDIT_SERVICE_API_KEY` en el `docker-compose.dev.yml` de cada repo. Ver
README.md de este repo, sección "Dev: key compartida" -- ese valor nunca debe
salir de un entorno de un solo host y nunca debe tratarse como las keys de
esta tabla.
