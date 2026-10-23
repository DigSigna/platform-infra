#!/usr/bin/env bash
# Genera una API key estática por servicio productor de eventos de auditoría
# y la aplica directo al cluster como un Secret de Kubernetes. Resuelve el gap
# de autenticación productor->audit-service documentado en docs/plan.md y
# docs/service-key-map.md -- este script NO decide cómo cada servicio usa la
# key (eso es go-common/py-common, otra tarea), sólo la genera y la deja
# disponible en el cluster.
#
# Nunca escribe el valor real en ningún archivo del repo. Lo imprime una sola
# vez a stdout (para copiar a un gestor de secretos si hace falta fuera del
# cluster) y lo aplica al cluster vía `kubectl ... | kubectl apply -f -`, no
# `kubectl create`, para que rotar una key sea correr este script de nuevo,
# no una operación destructiva que primero haya que borrar a mano.
#
# Uso:
#   ./generate-service-keys.sh                  # genera/rota las 5 keys
#   ./generate-service-keys.sh hsm-service       # sólo esa (rotación puntual)
#   NAMESPACE=otro-ns ./generate-service-keys.sh # namespace distinto al default
#
# Después de correrlo: actualizar a mano la fila correspondiente en
# docs/service-key-map.md con la fecha y el fingerprint que este script
# imprime (el script no toca ese archivo -- ver README.md).

set -euo pipefail

NAMESPACE="${NAMESPACE:-digsigna}"

# Productores confirmados contra audit-service hoy (docs/plan.md listaba 4;
# verification-service usa el mismo wiring de py-common/audit hybrid que
# certificate-service y signing-service -- AUDIT_ENABLED/AUDIT_STRATEGY en su
# config.py y docker-compose.dev.yml -- así que es un productor real aunque
# el plan original no lo mencionara). NO incluye audit-service (es quien
# valida, no quien produce) ni api-gateway (todavía no existe como servicio)
# -- agregar una línea acá cuando api-gateway exista de verdad, no antes.
declare -A SERVICE_SECRETS=(
  [hsm-service]="hsm-service-audit-key"
  [certificate-service]="certificate-service-audit-key"
  [signing-service]="signing-service-audit-key"
  [identification-service]="identification-service-audit-key"
  [verification-service]="verification-service-audit-key"
)

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: falta '$1' en el PATH." >&2
    exit 1
  fi
}

require_cmd kubectl
require_cmd openssl

targets=("$@")
if [ ${#targets[@]} -eq 0 ]; then
  targets=("${!SERVICE_SECRETS[@]}")
fi

for service in "${targets[@]}"; do
  secret_name="${SERVICE_SECRETS[$service]:-}"
  if [ -z "$secret_name" ]; then
    echo "Error: '$service' no es un productor conocido. Válidos: ${!SERVICE_SECRETS[*]}" >&2
    exit 1
  fi

  key="$(openssl rand -hex 32)"
  fingerprint="sha256:$(printf '%s' "$key" | openssl dgst -sha256 -hex | awk '{print $2}' | cut -c1-12)"
  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # --dry-run=client -o yaml | apply -f - hace esto idempotente: la primera
  # vez crea el Secret, las siguientes lo reemplaza en el lugar. Así rotar
  # una key es correr este script de nuevo, nunca un `kubectl delete` previo.
  kubectl create secret generic "$secret_name" \
    --from-literal=api_key="$key" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo
  echo "== $service =="
  echo "secret:      $secret_name (namespace: $NAMESPACE)"
  echo "fingerprint: $fingerprint"
  echo "generado:    $generated_at"
  echo "key (copiar ahora, no se vuelve a mostrar): $key"
  echo
  echo "Actualizar la fila de '$service' en docs/service-key-map.md con el"
  echo "fingerprint y la fecha de arriba -- el valor real de la key no va ahí."
  echo
done
