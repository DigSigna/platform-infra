Tarea: generar las API keys estáticas por servicio que autenticarán a los productores
de eventos de auditoría (hsm-service, certificate-service, signing-service,
identification-service, y a futuro api-gateway) contra audit-service, más el mapa
de registro y el mecanismo de distribución. Esto resuelve el gap confirmado: hoy
ningún productor puede autenticarse contra POST /api/v1/events de audit-service.

Repo: platform-infra (nuevo, recién creado — ver README.md para el alcance completo
del repo; esta tarea es sólo la parte de generación/mapa/distribución).

Alcance de esta tarea (sólo esto — el consumo de la key en cada servicio, en
go-common/py-common, y la validación del lado de audit-service son tareas
separadas, NO las hagas aquí):

1. Script de generación (scripts/generate-service-keys.sh o .py, el que prefieras
   según el resto de scripts del repo): genera una key aleatoria criptográficamente
   segura (openssl rand -hex 32, o el equivalente en el lenguaje que uses — nunca
   math/random ni un UUID como sustituto de entropía real) por cada servicio
   productor. El script NO debe escribir las keys reales en ningún archivo que
   se vaya a commitear — las aplica directo al cluster (kubectl create secret
   generic <nombre> --from-literal=api_key=<valor> -n <namespace>, o el
   equivalente) y, como mucho, imprime cada key una sola vez a stdout para que
   quien lo corre la copie a su gestor de secretos si la necesita fuera del
   cluster. Mismo principio que ya aplica en todo el proyecto: nunca hardcodear
   secretos en el repo, ni siquiera "temporalmente".

2. Manifiestos de Secret (k8s/service-keys/<servicio>.secret.yaml): la FORMA del
   Secret de Kubernetes para cada servicio (apiVersion, kind, metadata.name,
   type: Opaque, data: {} vacío o con un placeholder explícito como
   "<GENERADO-POR-SCRIPT-NO-COMMITEAR-VALOR-REAL>") — el valor real lo pone el
   script de arriba al aplicar, nunca el archivo del repo.

3. El mapa (docs/service-key-map.md): tabla con columnas
   servicio | nombre del Secret en k8s | namespace | permiso otorgado | fecha de
   generación | fingerprint o hash corto de la key (no el valor crudo, sólo para
   poder confirmar "esta es la key vigente" sin exponerla) — así cualquiera puede
   auditar quién tiene acceso a qué sin que el documento sea en sí mismo un secreto.
   Audit-service no genera su propia key aquí — es quien valida, no quien produce
   eventos; si audit-service necesita su propia credencial para algo (p. ej. un
   futuro endpoint administrativo), trátalo aparte, no lo mezcles con esta tabla.

4. Distribución para dev: una sola key estática fake, compartida por todos los
   servicios productores en docker-compose.dev.yml de cada repo — consistente con
   el patrón ya existente de KEYCLOAK_ADMIN_PASSWORD=admin en identification-service
   (válido porque es un entorno efímero de un solo host, sin salida de red real).
   Documenta esa key fake en el README de platform-infra como "NUNCA usar fuera de
   dev", no la trates con el mismo cuidado que las keys de producción del punto 1.

5. README.md del repo (o una sección si ya existe): explica en 3-4 líneas qué es
   este mecanismo, por qué existe (el gap de autenticación productor→audit-service),
   y cómo correr el script de generación la primera vez.

Fuera de alcance explícito (no lo toques en esta tarea):
- Cómo hsm-service/certificate-service/signing-service/identification-service
  envían la key en sus llamadas HTTP (eso es go-common y py-common, otra tarea).
- Cómo audit-service valida la key y cruza service_name contra ella (otra tarea).
- El cliente JS de identification-service hacia audit-service (si existe) — mismo
  criterio, otra tarea.
- Cualquier cosa de api-gateway — todavía no existe como servicio.

Al terminar: confirma que ningún archivo commiteado en el repo contiene un valor
de key real (grep -r sobre el diff antes de hacer push es razonable), y que el
script de generación se puede correr de nuevo sin romper nada si una key necesita
rotarse manualmente en el futuro (no hace falta automatizar la rotación todavía,
sólo que no sea una operación destructiva por accidente).