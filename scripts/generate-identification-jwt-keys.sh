#!/usr/bin/env bash
# Genera el par RSA que identification-service usa para firmar JWT (RS256)
# y lo aplica al cluster como el Secret identification-service-jwt-keys.
# Resuelve el gap confirmado en docs/env-vars-inventory.md: sin esto, el
# servicio genera un par efímero en memoria al boot y cada restart de pod
# invalida todos los tokens activos.
#
# Nunca escribe la clave privada en ningún archivo del repo -- se genera en
# un directorio temporal, se aplica al cluster, y se borra el temporal al
# salir (trap). --dry-run=client -o yaml | apply -f -, mismo criterio que
# el resto de scripts/*.sh: rotar es correr este script de nuevo, nunca un
# delete manual primero (aunque rotar esta key en particular invalida TODOS
# los JWT emitidos hasta ese momento -- a diferencia de las audit keys, no
# es una operación sin impacto).
#
# Uso:
#   ./generate-identification-jwt-keys.sh
#   NAMESPACE=otro-ns ./generate-identification-jwt-keys.sh

set -euo pipefail

NAMESPACE="${NAMESPACE:-digsigna}"
SECRET_NAME="identification-service-jwt-keys"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: falta '$1' en el PATH." >&2
    exit 1
  fi
}

require_cmd kubectl
require_cmd openssl

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

openssl genrsa -out "$tmp_dir/private.pem" 2048 2>/dev/null
openssl rsa -in "$tmp_dir/private.pem" -pubout -out "$tmp_dir/public.pem" 2>/dev/null

kubectl create secret generic "$SECRET_NAME" \
  --from-file=private.pem="$tmp_dir/private.pem" \
  --from-file=public.pem="$tmp_dir/public.pem" \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "Secret '$SECRET_NAME' aplicado (namespace: $NAMESPACE)."
echo "ADVERTENCIA: rotar este par invalida TODOS los JWT emitidos hasta ahora."
echo "El Deployment de identification-service debe montarlo como volumen y"
echo "apuntar JWT_PRIVATE_KEY_PATH/JWT_PUBLIC_KEY_PATH a ese mount."
echo
