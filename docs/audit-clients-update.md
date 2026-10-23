Tarea: hacer que los tres clientes productores de eventos de auditoría envíen la
API key de servicio (generada en platform-infra, punto 3) al llamar a
POST /api/v1/events de audit-service. Hoy ninguno manda ningún header de
autenticación — por eso cada llamada real sería rechazada por el
AuthMiddleware de audit-service. Esta tarea es sólo el lado productor (enviar
la key); la validación del lado de audit-service es una tarea aparte, no la
toques aquí.

Alcance: tres módulos, cada uno con su propio cliente/transporter de auditoría
ya existente — no crees nada nuevo desde cero, localiza el componente real en
cada repo antes de tocar código:

1. go-common (repo go-common, consumido por hsm-service y audit-service):
   localiza el HttpTransporter de auditoría (el que hace la llamada HTTP real
   hacia audit-service). Agrega:
   - Un campo de config nuevo (mismo patrón que el resto de config de
     go-common/hsm-service, vía viper) para la API key del servicio —
     sugerencia de nombre: AUDIT_API_KEY / audit.api_key.
   - Un header nuevo en la request saliente: X-Service-API-Key: <valor>.
     No reutilices el esquema Authorization/Bearer que ya existe para JWT de
     usuario — son dos mecanismos de auth distintos (servicio-a-servicio vs.
     usuario), mezclarlos confundiría el AuthMiddleware del lado de
     audit-service cuando se implemente.
   - Si la key no está configurada (vacía), loguea un error claro al
     arrancar o al primer intento de envío — pero NO bloquees ni rompas el
     circuit breaker/hybrid processor existente: el comportamiento de
     resiliencia ya construido (reintentos, fallback) no debe cambiar, sólo
     se le agrega el header cuando hay valor.

2. py-common (repo py-common, consumido por certificate-service y
   signing-service): localiza el equivalente Python del HttpTransporter de
   arriba (http_audit_transporter.py o como se llame en este repo). Mismo
   tratamiento: campo de config nuevo vía pydantic-settings, mismo nombre de
   variable de entorno (AUDIT_API_KEY) para que sea consistente entre Go y
   Python, mismo header X-Service-API-Key, mismo criterio de "falta la key
   → logueá, no rompas el circuit breaker".

3. identification-service (cliente nativo JS, NO pasa por go-common/py-common
   porque este servicio nunca extrajo su auditoría a un módulo común): localiza
   el AuditLogger (src/core/.../audit-logger.js o donde viva) y su método
   sendToAuditService(), que hoy es un TODO sin integración HTTP real.
   Implementa ahora la llamada real (fetch nativo, mismo patrón que ya usan
   infrastructure/keycloak/{admin-client,auth-client}.js para no agregar una
   dependencia nueva): POST al endpoint de audit-service configurado, con el
   mismo header X-Service-API-Key, la key leída de la misma variable de
   entorno AUDIT_API_KEY vía src/core/config. Si falla la llamada, no
   propagues el error hacia quien dispara el evento de auditoría (logueá y
   sigue) — la auditoría nunca debe tumbar una operación de negocio.

Dev vs. producción (ya decidido, no lo reabras):
- Dev: los tres servicios usan la misma key estática fake documentada en
  platform-infra/README.md — agrégala a cada docker-compose.dev.yml
  correspondiente (hsm-service, certificate-service, signing-service,
  identification-service) como AUDIT_API_KEY=<el valor fake acordado>, mismo
  criterio que KEYCLOAK_ADMIN_PASSWORD=admin.
- Producción: cada servicio recibe SU PROPIA key real vía el Secret de
  Kubernetes que platform-infra genera y aplica (punto 3) — en los manifiestos
  de despliegue de cada servicio (fuera de este repo, en los charts/manifiestos
  de producción si ya existen, o señalalo como pendiente si todavía no hay
  manifiesto de producción para ese servicio) hay que montar ese Secret como la
  variable de entorno AUDIT_API_KEY. Si no encontrás dónde vive el manifiesto
  de producción de alguno de los cuatro servicios, no lo inventes — señalalo
  como gap y seguí con el resto.

Fuera de alcance explícito:
- No toques audit-service (ni su AuthMiddleware, ni cómo valida la key, ni el
  cruce contra service_name) — es la tarea siguiente, separada.
- No toques api-gateway — no existe todavía.
- No cambies el formato del payload del evento de auditoría salvo que ya
  incluya service_name (si no lo incluye, señalalo, pero agregarlo es decisión
  aparte, no la tomes en esta tarea).

Al terminar: corré los tests existentes de cada uno de los tres módulos
(go-common, py-common, identification-service) y agregá un test nuevo por
módulo que confirme que el header se manda cuando hay key configurada y que
el comportamiento de resiliencia (circuit breaker / no-propagar-error) sigue
intacto cuando no la hay.