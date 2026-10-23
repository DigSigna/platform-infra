# platform-infra

Infraestructura compartida entre los servicios de DigSigna que no pertenece a
ninguno de ellos individualmente (manifiestos de Kubernetes, scripts de
generación de secretos, documentación de mapeo). Ver `STRUCTURE.md` para el
alcance completo planeado del repo.

## API keys de servicio para audit-service

Hoy ningún servicio productor de eventos de auditoría (hsm-service,
certificate-service, signing-service, identification-service; a futuro
api-gateway) puede autenticarse contra `POST /api/v1/events` de audit-service
-- el transporte HTTP de `go-common`/`py-common` postea eventos sin ninguna
credencial. Este mecanismo resuelve esa parte: genera una API key estática
por servicio productor, documenta quién tiene cuál en
`docs/service-key-map.md`, y la aplica al cluster como un Secret de
Kubernetes (`k8s/service-keys/`) sin que el valor real pase nunca por el
repo. Cómo cada servicio usa esa key en sus llamadas HTTP y cómo
audit-service la valida son tareas aparte (go-common/py-common y
audit-service, respectivamente).

Para generar (o rotar) las keys la primera vez:

```sh
cd scripts
./generate-service-keys.sh
```

Imprime cada key una sola vez a stdout (cópiala a tu gestor de secretos si la
necesitás fuera del cluster) y la aplica directo al namespace `digsigna` via
`kubectl`. Después de correrlo, actualizá a mano la fila correspondiente en
`docs/service-key-map.md` con la fecha y el fingerprint que imprime -- nunca
el valor real de la key.

## Dev: key compartida

En `docker-compose.dev.yml` de cada servicio productor, `AUDIT_SERVICE_API_KEY`
es una única key fake estática, igual en los 4 repos -- mismo criterio que
`KEYCLOAK_ADMIN_PASSWORD=admin` en identification-service: válido porque es
un entorno efímero de un solo host, sin salida de red real. **Nunca usar esa
key fuera de dev.** El valor fake es:

```
AUDIT_SERVICE_API_KEY=dev-audit-shared-key-never-use-outside-dev
```
