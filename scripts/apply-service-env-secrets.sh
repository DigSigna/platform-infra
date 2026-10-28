#!/usr/bin/env bash
# Genera el Secret "<servicio>-env" de cada uno de los 7 servicios a partir
# de k8s/envs/<servicio>.env (gitignored, con valores reales -- copiado de
# k8s/envs/<servicio>.env.example) y lo aplica al cluster. Mismo patrón que
# scripts/generate-service-keys.sh: --dry-run=client -o yaml | apply -f -,
# para que aplicar de nuevo tras editar el .env sea idempotente, nunca un
# `kubectl delete` manual primero.
#
# Este script NO genera valores (a diferencia de generate-service-keys.sh):
# los valores reales ya tienen que estar escritos en el .env de cada
# servicio antes de correrlo -- ver k8s/README.md.
#
# Uso:
#   ./apply-service-env-secrets.sh                        # aplica los 7
#   ./apply-service-env-secrets.sh hsm-service audit-service  # sólo esos
#   NAMESPACE=otro-ns ./apply-service-env-secrets.sh      # namespace distinto
#   ENV_DIR=/otra/ruta ./apply-service-env-secrets.sh     # dir distinto

set -euo pipefail

NAMESPACE="${NAMESPACE:-digsigna}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="${ENV_DIR:-$SCRIPT_DIR/../k8s/envs}"

declare -A SERVICES=(
  [identification-service]="identification-service-env"
  [hsm-service]="hsm-service-env"
  [certificate-service]="certificate-service-env"
  [signing-service]="signing-service-env"
  [verification-service]="verification-service-env"
  [gateway-service]="gateway-service-env"
  [audit-service]="audit-service-env"
)

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: falta '$1' en el PATH." >&2
    exit 1
  fi
}

require_cmd kubectl

targets=("$@")
if [ ${#targets[@]} -eq 0 ]; then
  targets=("${!SERVICES[@]}")
fi

for service in "${targets[@]}"; do
  secret_name="${SERVICES[$service]:-}"
  if [ -z "$secret_name" ]; then
    echo "Error: '$service' no es un servicio conocido. Válidos: ${!SERVICES[*]}" >&2
    exit 1
  fi

  env_file="$ENV_DIR/$service.env"
  if [ ! -f "$env_file" ]; then
    echo "Error: falta $env_file (copiar de $service.env.example y completar con valores reales)." >&2
    exit 1
  fi

  kubectl create secret generic "$secret_name" \
    --from-env-file="$env_file" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo "== $service: Secret '$secret_name' aplicado (namespace: $NAMESPACE) =="
done
