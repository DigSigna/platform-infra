# Plan de migración: salir de ingress-nginx

**EJECUTADO el 2026-11-20.** Este documento se escribió como plan antes
de ejecutar nada; se deja tal cual abajo como el razonamiento original,
pero la ejecución real difirió en varios puntos concretos -- ver
"Epílogo: qué pasó de verdad" al final del documento para el detalle, y
`k8s/README.md` (sección "Migración de ingress-nginx a Gateway API")
para los comandos exactos que quedaron documentados para reinstalar o
reproducir esto. Los manifiestos vigentes son `k8s/gateway/*.yaml`
(reemplazan a `k8s/ingress/`, ya borrado).

**Contexto (2026-11-20):** el proyecto Kubernetes SIG-Network
`ingress-nginx` está retirado -- mantenimiento terminado en marzo 2026,
última release `v1.15.1` (la que ya corre en este cluster), repo
archivado, sin más backports ni parches de seguridad nunca. CVE-2026-116472
(DoS vía la anotación `mirror-target`) ya se mitigó a mano
(`annotations-risk-level: Medium` en el ConfigMap, ver `k8s/README.md`),
pero es un parche, no una solución -- cualquier CVE nueva que aparezca de
acá en adelante no tendrá fix upstream posible. Este documento es el plan
para salir de ingress-nginx hacia un controller con mantenimiento activo,
no una ejecución inmediata -- nada de esto se aplica hasta que el equipo
decida la fecha.

## 1. Qué hace hoy ingress-nginx en este proyecto (y qué no)

Confirmado contra el cluster real (`do-nyc1-digsigna-prod-doks`), no
asumido:

- **Un solo nodo**, `ingress-nginx-controller` corre con
  `hostNetwork: true` sobre ese nodo (no hay `Service type: LoadBalancer`
  de DigitalOcean -- el `Service` es `ClusterIP`, el nodo mismo escucha
  80/443). El A record de `api.firmasdigitales.com.mx` apunta a la IP
  pública de ESE nodo (ya señalado como gap manual en
  `k8s/ingress/gateway-ingress.yaml`: si el nodo se reemplaza, hay que
  actualizar el A record a mano).
- **Un solo `Ingress`** en todo el cluster (`gateway-ingress.yaml`): un
  host (`api.firmasdigitales.com.mx`), una sola regla (`/` ->
  `gateway-service:8080`), una sola anotación real
  (`nginx.ingress.kubernetes.io/proxy-body-size: "15m"`, riesgo **Medium**
  en la clasificación de ingress-nginx).
- **cert-manager** (`v1.21.3`) resuelve el challenge ACME HTTP-01 con el
  solver `http01.ingress.ingressClassName: nginx` (`letsencrypt-clusterissuer.yaml`)
  -- es decir, también depende del tipo de recurso (`Ingress` vs
  `Gateway`/`HTTPRoute`), no solo del controller.

**Lo que ingress-nginx NO hace, y por lo tanto no es parte de este
plan:** todo el enrutamiento real entre los 6 servicios de aplicación
(identification, hsm, certificate, signing, verification, audit), la
autenticación JWT/JWKS, el rate limiting (Redis) y el audit log de cada
request viven dentro de **gateway-service** (Go, `router.go` +
`config.production.yaml`, ver `k8s/configmaps/gateway-service-config.yaml`).
ingress-nginx hoy es una capa de borde muy delgada: termina TLS y reenvía
TODO a `gateway-service:8080`, nada más. Cambiar el controller de borde
**no toca gateway-service ni su configuración** -- sigue siendo el único
backend, con el mismo contrato (`Service` ClusterIP en el puerto 8080,
mismos `/health`/`/ready`). Esto acota mucho el riesgo de la migración:
la superficie real a migrar es un host, una ruta y una anotación de
tamaño de body, no la lógica de negocio del gateway.

## 2. Opciones evaluadas

| | **NGINX Gateway Fabric** | **Envoy Gateway** | **Traefik** |
|---|---|---|---|
| Mantenedor | F5/NGINX (mismo vendor que nginx), proyecto oficial de la comunidad Gateway API | CNCF, multi-vendor (Envoy Proxy) | Traefik Labs |
| Motor de datos | nginx (el mismo binario, reconfigurado vía Gateway API en vez de `Ingress`+anotaciones) | Envoy (proxy xDS, arquitectura distinta a nginx) | Binario propio en Go, su propio proxy |
| Estándar | Gateway API (`GatewayClass`/`Gateway`/`HTTPRoute`), CNCF | Gateway API, uno de los más conformantes | Gateway API (soportado) + CRDs propios (`IngressRoute`) + `Ingress` clásico |
| Riesgo de abandono | Bajo -- vendor único con interés comercial directo (nginx), y el estándar Gateway API es portable a otro implementador si F5 lo abandonara | Bajo -- gran tracción multi-vendor (Google, varios proveedores cloud) | Medio -- empresa pequeña, ya hay funcionalidades movidas hacia Traefik Hub (producto comercial) en releases recientes |
| Continuidad operativa con hoy | **Alta** -- mismo modelo mental (nginx.conf generado, reload), equipo ya conoce nginx | Baja -- debugging vía xDS/Envoy, sin `nginx -T` para leer la config generada | Media -- otro modelo (routers/middlewares), pero muy simple de leer |
| `hostNetwork` en un solo nodo | Soportado (mismo patrón, Helm chart expone la opción) | Soportado | Soportado |
| Equivalente de `proxy-body-size` | `ClientSettingsPolicy` (CRD propio de NGF) referenciando el `HTTPRoute` | `BackendTrafficPolicy` (`Envoy Gateway` CRD) | Middleware `buffering` (`maxRequestBodyBytes`) vía `IngressRoute`/`HTTPRoute` |
| cert-manager HTTP-01 | Sí, vía solver `http01.gatewayHTTPRoute` (soportado desde cert-manager 1.5, confirmado disponible en 1.21.3 ya instalado) | Igual, `gatewayHTTPRoute` | Igual, `gatewayHTTPRoute` (o puede seguir usando `Ingress` clásico sin tocar el solver) |
| Huella de recursos (1 nodo pequeño) | Baja, similar a ingress-nginx hoy | Media/alta -- Envoy consume más que nginx en reposo | Baja, un solo binario |
| Curva de aprendizaje para el equipo | Baja (CRDs nuevos, pero concepto nginx ya conocido) | Alta (Envoy/xDS es un paradigma distinto) | Baja/Media |

## 3. Recomendación: NGINX Gateway Fabric

Para el tamaño y la forma real de este proyecto (un host, una ruta, un
solo backend, un solo nodo, equipo pequeño sin plataforma dedicada de
networking) el criterio decisivo no es la lista de features sino **no
repetir exactamente el problema que originó este documento**: quedarse
atado a un proyecto que se abandona. Dos razones concretas:

1. **Gateway API es el estándar, no el producto.** Si NGINX Gateway
   Fabric se abandonara en el futuro, los recursos `Gateway`/`HTTPRoute`
   son portables casi sin cambios a Envoy Gateway, Traefik o cualquier
   otro implementador conformante -- a diferencia de hoy, donde todo el
   repo está escrito en anotaciones específicas de ingress-nginx
   (`nginx.ingress.kubernetes.io/...`) que no significan nada para otro
   controller. Adoptar Gateway API es la parte del cambio que realmente
   reduce el riesgo a largo plazo, más allá de cuál implementador se
   elija hoy.
2. **Menor delta operativo.** Sigue siendo nginx por debajo -- mismo
   modelo de reload, mismo tipo de logs de acceso, mismo
   comportamiento de `proxy-body-size` conceptualmente (solo cambia la
   forma de declararlo). El equipo no tiene que aprender Envoy/xDS para
   depurar un problema de borde a las 2am.

Envoy Gateway es la opción correcta SI este proyecto fuera a crecer hacia
necesidades reales de traffic management en el borde (canary releases,
mTLS entre servicios, varios Gateways/hosts, políticas de tráfico
complejas) -- hoy esa lógica ya vive dentro de gateway-service, así que
Envoy Gateway resolvería problemas que este proyecto no tiene, al costo
de una curva de aprendizaje y una huella de recursos mayores. Traefik es
una alternativa razonable si se prefiere evitar instalar las CRDs de
Gateway API por ahora (puede seguir usando `Ingress` clásico sin
cambiar `letsencrypt-clusterissuer.yaml`), pero no resuelve la razón 1
de arriba, y el movimiento reciente de funcionalidad hacia Traefik Hub
(producto comercial) es una señal de riesgo de roadmap a vigilar.

## 4. Impacto en el proyecto

### 4.1. gateway-service: ningún cambio

`gateway-service` no sabe ni le importa qué hay delante de él. Sigue
siendo un `Service` ClusterIP en el puerto 8080, con los mismos
`/health`/`/ready`, la misma config
(`k8s/configmaps/gateway-service-config.yaml`), el mismo rate limiting
contra Redis y el mismo audit log hacia `audit-service`. Lo único que
cambia es **cómo se le declara como backend**: hoy
`Ingress.spec.rules[].http.paths[].backend.service` (ver
`k8s/ingress/gateway-ingress.yaml`), con NGINX Gateway Fabric pasa a ser
`HTTPRoute.spec.rules[].backendRefs[]` apuntando al mismo `Service`
`gateway-service:8080` -- mismo nombre, mismo puerto, ningún cambio en
`k8s/deployments/gateway-service.yaml`.

### 4.2. Archivos de este repo que cambian

- `k8s/ingress/gateway-ingress.yaml` -- se reemplaza por (nuevo
  directorio sugerido `k8s/gateway/`):
  - `gatewayclass.yaml` (`GatewayClass` apuntando al controller de NGF,
    uno solo para todo el cluster, análogo a como hoy
    `ingressClassName: nginx` es uno solo)
  - `gateway.yaml` (`Gateway` con los listeners 80/443 -- acá se declara
    `hostNetwork` o el tipo de exposición del Service, equivalente a la
    decisión que hoy toma el Helm release de ingress-nginx)
  - `httproute.yaml` (reemplaza las `rules` del `Ingress`: host
    `api.firmasdigitales.com.mx`, backend `gateway-service:8080`)
  - un `ClientSettingsPolicy` (o el CRD equivalente que publique la
    versión de NGF que se instale) para el límite de 15m, con el mismo
    razonamiento que ya documenta el `Ingress` actual (ver su comentario
    de cabecera) -- **no perder esa justificación al migrar**, copiarla.
- `k8s/ingress/letsencrypt-clusterissuer.yaml` -- el solver cambia de
  ```yaml
  solvers:
  - http01:
      ingress:
        ingressClassName: nginx
  ```
  a
  ```yaml
  solvers:
  - http01:
      gatewayHTTPRoute:
        parentRefs:
        - name: <nombre-del-Gateway>
          namespace: digsigna
  ```
- `k8s/README.md` -- actualizar el paso 11 ("Instalar ingress-nginx")
  por el equivalente de NGF, y retirar la nota de mitigación de
  CVE-2026-116472 una vez que ingress-nginx ya no esté instalado.
- `terraform/modules/firewall/README.md` -- el punto ya abierto ahí
  ("según cómo exponga el Service el Ingress Controller, puede hacer
  falta el rango de NodePort") se re-evalúa igual para NGF: si se
  mantiene el mismo patrón `hostNetwork` de un solo nodo, no cambia
  nada del firewall; si se decide pasar a `Service type: LoadBalancer`
  de DigitalOcean en el mismo movimiento, sí hay que revisar esa regla.

### 4.3. Lo que NO cambia

- El patrón de un solo nodo con `hostNetwork` puede mantenerse igual
  (NGF lo soporta) -- esta migración no obliga a resolver el gap ya
  señalado del A record manual, aunque sería un buen momento para
  reconsiderarlo si el equipo quiere resolver los dos a la vez.
- El dominio, el `Secret` TLS (`gateway-tls`, gestionado por
  cert-manager) y el `ClusterIssuer` en sí (`letsencrypt-prod`) -- solo
  cambia el `solver`, no el issuer ni el certificado ya emitido (se
  re-valida solo en el próximo renew).
- Los otros 5 servicios de aplicación y toda su configuración --
  ninguno es backend de ningún `Ingress`/`Gateway`, por diseño (ver
  `terraform/modules/firewall/README.md`).

## 5. Pasos de migración sugeridos (alto nivel, sin fecha)

1. Instalar NGINX Gateway Fabric vía Helm en un `GatewayClass` nuevo,
   **en paralelo** con ingress-nginx (no reemplazarlo todavía) --
   usando un listener en puertos distintos (p.ej. 8080/8443 de prueba,
   no 80/443) para no competir por el `hostNetwork` del único nodo.
2. Crear `Gateway`+`HTTPRoute` de prueba apuntando al mismo
   `gateway-service:8080`, probar con `curl --resolve` contra la IP del
   nodo en el puerto de prueba (sin tocar DNS real todavía).
3. Validar: TLS (emitir un certificado de prueba con el staging ACME de
   Let's Encrypt, no el de producción, para no gastar el rate limit
   real), el límite de 15m de body size, y que las respuestas de
   `gateway-service` (incluido `/health`/`/ready`) pasen sin cambios.
4. Ventana de corte: cambiar los listeners de NGF a 80/443 (requiere
   bajar ingress-nginx primero si ambos usan `hostNetwork` sobre el
   mismo nodo -- no pueden competir por el mismo puerto), actualizar
   `letsencrypt-clusterissuer.yaml` al solver de Gateway API, re-emitir
   el certificado real.
5. Confirmar tráfico real funcionando (mismo smoke test que ya se usó
   para validar la mitigación de CVE-2026-116472: `curl` contra
   `api.firmasdigitales.com.mx` esperando 401, logs de NGF mostrando el
   reload/aplicación de config).
6. Desinstalar el Helm release de ingress-nginx y borrar
   `k8s/ingress/gateway-ingress.yaml` (o archivarlo), actualizar
   `k8s/README.md` para quitar la nota de mitigación (ya no aplica, el
   controller nuevo no tiene esa CVE).

## 6. Plan de rollback

Mientras el paso 4 no se ejecute, el rollback es trivial: borrar los
recursos de prueba de NGF, ingress-nginx nunca dejó de atender tráfico
real. Durante la ventana de corte (paso 4), si algo falla: reinstalar/
reescalar el Helm release de ingress-nginx y revertir
`letsencrypt-clusterissuer.yaml` al solver `ingress` -- por eso el paso 4
no debe borrar ingress-nginx hasta después de confirmar el paso 5.

## 7. Riesgos / preguntas abiertas

- **Un solo nodo, un solo controller a la vez en 80/443**: no hay forma
  de tener ingress-nginx y NGF corriendo ambos en `hostNetwork:80/443`
  del mismo nodo simultáneamente -- la ventana de corte del paso 4 tiene
  un downtime real (breve) salvo que se agregue un segundo nodo temporal
  para la transición. A decidir con el equipo si el downtime de la
  ventana de corte es aceptable o si vale la pena el costo de un nodo
  extra temporal.
- **Versión exacta de NGF y su CRD de body-size**: el nombre del CRD
  (`ClientSettingsPolicy` u otro) depende de la versión de NGINX Gateway
  Fabric disponible al momento de ejecutar esto -- confirmar contra la
  documentación de la versión real antes de escribir el manifiesto,
  igual criterio que ya se aplica en todo este repo (nunca asumir, leer
  la fuente real).
- **Gateway API ya instalado en el cluster**: las CRDs base de Gateway
  API (`GatewayClass`, `Gateway`, `HTTPRoute`) no son parte de ningún
  Helm chart de controller -- hay que instalarlas aparte (manifiestos
  oficiales de `gateway-api`), un pre-requisito nuevo análogo a
  `ghcr-creds`/`cert-manager` hoy.

## Epílogo: qué pasó de verdad (ejecutado 2026-11-20)

Se decidió ejecutar esto el mismo día que se escribió el plan de arriba
-- el proyecto todavía no tenía tráfico real (sandbox, ~2 semanas antes
de la fecha prevista de paso a producción), así que el riesgo de
downtime de la sección 7 (que motivaba hacerlo en dos pasos, con
ventana de prueba separada) deja de aplicar: una ventana de corte de
minutos no le cuesta nada a nadie. Dicho eso, la ejecución real encontró
tres cosas que el plan de arriba no anticipaba:

1. **Cilium (el CNI de DOKS) ya trae Gateway API activado por default**,
   con una GatewayClass `cilium` propia y funcional desde que se creó el
   cluster -- no hacía falta instalar NADA para tener Gateway API
   corriendo. Se evaluó esta opción primero (sección 3 arriba no la
   consideraba porque no se sabía que existía) y se descartó: su
   `NginxProxy`-equivalente por default crea un `Service type:
   LoadBalancer`, un Load Balancer real de DigitalOcean con costo
   recurrente que el equipo no quería asumir. La alternativa (editar
   `cilium-config`, el ConfigMap que gestiona el addon de DOKS, para
   forzar el patrón sin LoadBalancer) se descartó también -- es un
   componente gestionado por DigitalOcean, no por este repo, y el mismo
   razonamiento que ya motivó la mitigación cuidadosa de CVE-2026-116472
   (no pelear por la propiedad de un campo que otro controller gestiona)
   aplica con más fuerza todavía a la configuración del CNI completo.
   Se instaló NGINX Gateway Fabric (NGF) en su lugar, como decía la
   sección 3 -- la recomendación de ese análisis se mantuvo, solo que
   por una razón adicional a las ya escritas (evitar el Load Balancer).
2. **Las CRDs estándar de Gateway API que Cilium ya tenía instaladas
   (v1.2.1) NO se actualizaron a v1.7.0** (la versión contra la que NGF
   2.9.0 está probado oficialmente, según su página de especificaciones
   técnicas). Un `kubectl apply --server-side` con las CRDs v1.7.0 dio
   conflicto: Cilium ya es el field manager de
   `GatewayClass`/`Gateway`/`HTTPRoute`/`GRPCRoute`/`ReferenceGrant`, y
   forzar la escritura con `--force-conflicts` se descartó por el mismo
   riesgo de reversión en la próxima reconciliación del addon. Se
   dejaron esas CRDs en v1.2.1 y se instalaron sin problema (Cilium no
   las tenía) las 4 CRDs nuevas de v1.7.0: `BackendTLSPolicy`,
   `ListenerSet`, `TCPRoute`, `UDPRoute`. Confirmado en producción que
   NGF 2.9.0 funciona correctamente sobre `Gateway`/`HTTPRoute` en
   v1.2.1 para el único host/ruta que usa este repo -- es un riesgo
   aceptado conscientemente (no una combinación que NGF garantice), no
   un problema real encontrado.
3. **El certificado no se reemitió**: `gateway-tls` (`Certificate` +
   `Secret`) ya estaba vigente (vence 2027-02-01) y es independiente del
   `Ingress` -- borrar el `Ingress` no lo tocó. Solo se actualizó el
   solver del `ClusterIssuer` para la próxima renovación automática, sin
   disparar ningún challenge ACME nuevo en esta migración -- de la
   sección 4.3 ("Lo que NO cambia") ya se anticipaba esto correctamente.

El resto del plan se ejecutó tal como estaba escrito: `daemonSet`+
`hostPorts` en vez de `Deployment`+`LoadBalancer` para el dataplane de
NGF (sección 4.2), reusando el mismo patrón de un solo nodo sin tocar
`terraform/modules/firewall` (confirmado, sigue bastando 80/443),
`ClientSettingsPolicy` para el límite de 15m (validado con POSTs de
10MB y 16MB contra el dominio real, igual comportamiento que
`proxy-body-size` antes), y desinstalación completa de ingress-nginx al
final (sección 5, pasos 4-6).
