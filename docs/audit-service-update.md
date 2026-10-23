Tarea: implementar en audit-service la autenticación de servicios productores
contra POST /api/v1/events, usando las API keys estáticas por servicio que
platform-infra genera y distribuye (punto 3) y que hsm-service/certificate-
service/signing-service/identification-service ya envían como header
X-Service-API-Key (tarea anterior, ya hecha en go-common/py-common/el cliente
JS nativo). Hoy esta ruta exige ValidateJWT()+RequirePermission("audit:event:
write") — ningún productor tiene nunca un JWT de usuario para presentar, así
que la ruta está rota end-to-end. Esta tarea es sólo el lado receptor
(validar la key); ya no toques los clientes productores, eso quedó cerrado.

Cambio central: POST /api/v1/events deja de usar ValidateJWT()/RequirePermission
para su autenticación — ese middleware es para endpoints de usuario final, no
para llamadas servicio-a-servicio. Reemplázalo en esta ruta específica por un
middleware nuevo, p. ej. ServiceKeyAuthMiddleware, que:

1. Lee el header X-Service-API-Key. Si falta o está vacío, responde 401 sin
   tocar el body del evento.
2. Resuelve a qué servicio corresponde esa key. Guarda en config (al arrancar,
   mismo patrón viper que el resto de audit-service) un mapa de
   servicio -> hash SHA-256 de su key esperada, cargado desde variables de
   entorno (una por servicio: AUDIT_KEY_HSM_SERVICE, AUDIT_KEY_CERTIFICATE_
   SERVICE, AUDIT_KEY_SIGNING_SERVICE, AUDIT_KEY_IDENTIFICATION_SERVICE — nunca
   la key cruda en config.yaml ni en el repo). Nunca compares la key presentada
   contra el hash guardado con == directo — usá crypto/subtle.
   ConstantTimeCompare (mismo criterio de comparación segura que ya usa
   identification-service para su BOOTSTRAP_SECRET con crypto.
   timingSafeEqual, adaptado a Go) para no abrir un canal de timing attack.
3. Si la key no coincide con ningún servicio conocido, 401 — y logueá el
   intento (sin la key cruda, nunca material criptográfico en logs, mismo
   criterio que el resto del proyecto), para poder detectar una key filtrada o
   mal distribuida.
4. Si coincide, adjunta el nombre del servicio autenticado al contexto de la
   request (p. ej. c.Set("authenticated_service", serviceName)) para que el
   handler lo use en el paso 5.

5. En el handler de POST /api/v1/events (después del middleware, antes de
   persistir): compará el service_name que venga en el body del evento contra
   authenticated_service del contexto. Si no coinciden, 403 — esto es lo que
   evita que un servicio autenticado con su propia key reporte eventos
   haciéndose pasar por otro. Si el body no tiene hoy un campo service_name,
   agrégalo al schema del evento (y avisa en el PR que era necesario agregarlo,
   no lo asumas ya existente sin verificar contra el código real).

Dev: la misma key fake estática compartida (ya documentada en platform-infra)
se acepta para los cuatro nombres de servicio en el mapa de config de
desarrollo — así no hay que generar cuatro keys fake distintas sólo para dev,
consistente con que todos los productores en dev mandan la misma key hoy.

Fuera de alcance explícito:
- No toques go-common/py-common/el cliente JS de identification-service — ya
  envían el header, no hay nada más que hacer ahí.
- No construyas OAuth/client-credentials ni ningún esquema más allá de esta
  key estática + hash — ya se descartó esa opción al diseñar esto.
- Los demás endpoints de audit-service (si hay alguno de lectura/consulta
  pensado para usuarios finales) siguen con ValidateJWT()/RequirePermission
  tal cual — este cambio es sólo para la ruta de ingestión.
- No implementes rotación de keys todavía — sólo que el mapa de config
  soporte agregar una variable de entorno nueva sin tener que tocar código
  (ya debería ser así si se carga por nombre de servicio, confírmalo).

Al terminar: agregá tests que cubran los cuatro casos — key ausente (401),
key desconocida (401), key válida pero service_name del body no coincide con
el servicio autenticado (403), y el camino feliz (key válida + service_name
coincide → el evento se persiste). Corré también una prueba manual con curl
simulando a hsm-service contra el audit-service real de dev, con la key fake
compartida, para confirmar que el pipeline completo (que hoy está roto) ya
funciona de punta a punta.