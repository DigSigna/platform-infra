# modules/firewall

Cloud Firewall de borde para los nodos del node pool de DOKS. Regla de
diseño: **solo 80/443 públicos**, pensados para el Ingress del cluster que
todavía no existe como recurso Terraform (se agrega después, como Helm
release o manifiesto de Kubernetes, no en este repo). Ningún backend
individual se expone acá — eso lo decide cada `Service`/`Ingress` de
Kubernetes hacia adentro del cluster, no el firewall de los droplets.

## Pendiente de validar con datos reales (no se puede hoy)

- `target_tag` tiene que ser un tag que realmente exista en los droplets
  del node pool. En `environments/prod/main.tf` se construye como
  `"${var.doks_name}-nodes"` y se pasa también al módulo `doks` — hay que
  confirmar, una vez aplicado, que el node pool efectivamente quedó
  tageado así (`doctl compute droplet list --tag-name <tag>` debería listar
  los nodos).
- Según qué Ingress Controller se elija y cómo lo expongan los Service de
  Kubernetes (`LoadBalancer` con `externalTrafficPolicy`, NodePort, o
  `hostNetwork`), puede hacer falta abrir además el rango de NodePort
  (por defecto `30000-32767`) para que el Load Balancer de DigitalOcean
  pueda reenviar tráfico de 80/443 al pod del Ingress. Esto se decide
  cuando se instale el Ingress, no antes — por ahora el firewall solo
  abre 80/443 tal como se pidió.

  **Resuelto (2026-11-20), no hizo falta:** primero ingress-nginx y luego
  NGINX Gateway Fabric (migración de Ingress a Gateway API, ver
  `k8s/README.md` y `docs/ingress-migration-plan.md`) se expusieron con
  el patrón `hostNetwork`/`hostPorts` sobre el único nodo del node pool,
  nunca `Service type: LoadBalancer`/`NodePort` -- confirmado en
  producción, 80/443 sigue siendo todo lo que este módulo necesita abrir.
  Sigue siendo cierto que si algún día se decide exponer el controller
  vía un Load Balancer real de DigitalOcean (por ejemplo al crecer a más
  de un nodo), este rango habría que abrirlo entonces.
