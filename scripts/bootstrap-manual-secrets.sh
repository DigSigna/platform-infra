#!/usr/bin/env bash
# Aplica los 4 Secrets "mecanismo 3" que k8s/README.md documenta
# deliberadamente como "a mano" (ghcr-creds, mysql-secrets, hsm-secrets,
# keycloak-secrets): no tienen forma KEY=VALUE simple, y sus valores son
# decisiones operativas (credenciales de GHCR, DSN de una MySQL real,
# PIN/master-key de HSM, admin de Keycloak), no algo que este repo deba
# inventar solo. Este script NO decide esos valores -- los toma de
# variables de entorno, y si falta alguna para un Secret que todavía no
# existe en el cluster, se detiene e imprime el comando exacto de
# k8s/README.md para aplicarlo a mano, en vez de seguir con un cluster a
# medio provisionar.
#
# Idempotente: un Secret que ya existe en el namespace se deja intacto y
# se saltea (nunca se borra/recrea solo), para no pisar una rotación hecha
# a mano entre corridas. Para forzar una actualización desde las variables
# de entorno, borrar el Secret primero (`kubectl delete secret <nombre> -n
# $NAMESPACE`) y volver a correr este script.
#
# Uso:
#   GHCR_USERNAME=... GHCR_TOKEN=... GHCR_EMAIL=... \
#   MYSQL_CONNECTION_STRING='mysql://user:pass@tcp(host:3306)/digsigna?tls=true' \
#   # (database_url se deriva solo de MYSQL_CONNECTION_STRING, no hace falta pasarlo aparte)
#   HSM_PIN=... HSM_MASTER_AES_KEY_V1=... \
#   KEYCLOAK_ADMIN_PASSWORD=... KEYCLOAK_DB_HOST=... KEYCLOAK_DB_PASSWORD=... \
#     ./bootstrap-manual-secrets.sh

set -euo pipefail

NAMESPACE="${NAMESPACE:-digsigna}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: falta '$1' en el PATH." >&2
    exit 1
  fi
}
require_cmd kubectl

secret_exists() {
  kubectl get secret "$1" -n "$NAMESPACE" >/dev/null 2>&1
}

apply_secret() {
  # apply_secret NOMBRE -- lee los --from-literal=... del resto de argumentos
  local name="$1"
  shift
  kubectl create secret generic "$name" "$@" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  echo "== Secret '$name' aplicado (namespace: $NAMESPACE) =="
}

missing_vars_message() {
  # missing_vars_message NOMBRE_SECRET COMANDO_DE_README
  echo "Error: falta el Secret '$1' y no están todas las variables de entorno para generarlo." >&2
  echo "Aplicarlo a mano (ver k8s/README.md):" >&2
  echo "$2" >&2
}

# --- 1. ghcr-creds (docker-registry, no es Opaque KEY=VALUE) ---------------
if secret_exists ghcr-creds; then
  echo "== Secret 'ghcr-creds' ya existe, se omite =="
elif [ -n "${GHCR_USERNAME:-}" ] && [ -n "${GHCR_TOKEN:-}" ] && [ -n "${GHCR_EMAIL:-}" ]; then
  kubectl create secret docker-registry ghcr-creds \
    --docker-server=ghcr.io \
    --docker-username="$GHCR_USERNAME" \
    --docker-password="$GHCR_TOKEN" \
    --docker-email="$GHCR_EMAIL" \
    -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  echo "== Secret 'ghcr-creds' aplicado (namespace: $NAMESPACE) =="
else
  missing_vars_message "ghcr-creds" "  kubectl create secret docker-registry ghcr-creds --docker-server=ghcr.io --docker-username=<usuario-github> --docker-password=<PAT-con-scope-read:packages> --docker-email=<email> -n $NAMESPACE
  (o exportar GHCR_USERNAME/GHCR_TOKEN/GHCR_EMAIL y volver a correr este script)"
  exit 1
fi

# --- 2. mysql-secrets -------------------------------------------------------
# Dos campos a partir de UNA sola variable de entrada (MYSQL_CONNECTION_STRING,
# formato tcp(host:puerto)): connection_string se guarda tal cual (lo que
# espera golang-migrate en migrations-job), y database_url se deriva
# quitándole el tcp(...) (lo que espera el parser propio de hsm-service --
# ver el comentario de cabecera de k8s/shared-secrets/mysql-secrets.secret.yaml,
# los dos formatos NO son intercambiables). Derivarlo así, en vez de pedir
# una segunda variable de entorno, evita que connection_string y database_url
# puedan quedar desincronizados entre sí.
if secret_exists mysql-secrets; then
  echo "== Secret 'mysql-secrets' ya existe, se omite =="
elif [ -n "${MYSQL_CONNECTION_STRING:-}" ]; then
  mysql_database_url="$(printf '%s' "$MYSQL_CONNECTION_STRING" | sed -E 's#@tcp\(([^)]*)\)/#@\1/#')"
  if [ "$mysql_database_url" = "$MYSQL_CONNECTION_STRING" ]; then
    echo "Error: MYSQL_CONNECTION_STRING no tiene la forma esperada '...@tcp(host:puerto)/...' -- no se pudo derivar database_url." >&2
    exit 1
  fi
  apply_secret mysql-secrets \
    --from-literal="connection_string=$MYSQL_CONNECTION_STRING" \
    --from-literal="database_url=$mysql_database_url"
else
  missing_vars_message "mysql-secrets" "  kubectl create secret generic mysql-secrets --from-literal=connection_string=\"mysql://usuario:password@tcp(host:3306)/digsigna?tls=true\" --from-literal=database_url=\"mysql://usuario:password@host:3306/digsigna?tls=true\" -n $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
  (o exportar MYSQL_CONNECTION_STRING y volver a correr este script)"
  exit 1
fi

# --- 3. hsm-secrets ----------------------------------------------------------
if secret_exists hsm-secrets; then
  echo "== Secret 'hsm-secrets' ya existe, se omite =="
elif [ -n "${HSM_PIN:-}" ] && [ -n "${HSM_MASTER_AES_KEY_V1:-}" ]; then
  apply_secret hsm-secrets \
    --from-literal="pin=$HSM_PIN" \
    --from-literal="master-aes-key-v1=$HSM_MASTER_AES_KEY_V1" \
    --from-literal="master-key-old=${HSM_MASTER_KEY_OLD:-}" \
    --from-literal="master-key-id=master-aes-key-v1" \
    --from-literal="so-pin=${HSM_SO_PIN:-}" \
    --from-literal="master-key=${HSM_MASTER_KEY:-}" \
    --from-literal="v1=${HSM_V1:-}"
else
  missing_vars_message "hsm-secrets" "  kubectl create secret generic hsm-secrets --from-literal=pin=<PIN> --from-literal=master-aes-key-v1=<master-key-AES> --from-literal=master-key-old= --from-literal=master-key-id=master-aes-key-v1 -n $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
  (o exportar HSM_PIN/HSM_MASTER_AES_KEY_V1 y volver a correr este script -- ver k8s/shared-secrets/hsm-secrets.secret.yaml para el resto de los campos)"
  exit 1
fi

# --- 4. keycloak-secrets ------------------------------------------------------
if secret_exists keycloak-secrets; then
  echo "== Secret 'keycloak-secrets' ya existe, se omite =="
elif [ -n "${KEYCLOAK_ADMIN_PASSWORD:-}" ] && [ -n "${KEYCLOAK_DB_HOST:-}" ] && [ -n "${KEYCLOAK_DB_PASSWORD:-}" ]; then
  apply_secret keycloak-secrets \
    --from-literal="admin-username=${KEYCLOAK_ADMIN_USERNAME:-admin}" \
    --from-literal="admin-password=$KEYCLOAK_ADMIN_PASSWORD" \
    --from-literal="db-url=jdbc:mysql://${KEYCLOAK_DB_HOST}:3306/keycloak?useSSL=true&requireSSL=true" \
    --from-literal="db-username=${KEYCLOAK_DB_USERNAME:-keycloak}" \
    --from-literal="db-password=$KEYCLOAK_DB_PASSWORD"
  echo "   IMPORTANTE: KEYCLOAK_ADMIN_PASSWORD tiene que copiarse también a"
  echo "   KEYCLOAK_ADMIN_PASSWORD en k8s/envs/identification-service.env (mismo"
  echo "   admin-cli, dos Secrets distintos -- ver k8s/README.md)."
else
  missing_vars_message "keycloak-secrets" "  kubectl create secret generic keycloak-secrets --from-literal=admin-username=<usuario> --from-literal=admin-password=<password> --from-literal=db-url=\"jdbc:mysql://<host>:3306/keycloak?useSSL=true&requireSSL=true\" --from-literal=db-username=<usuario-db> --from-literal=db-password=<password-db> -n $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
  (o exportar KEYCLOAK_ADMIN_PASSWORD/KEYCLOAK_DB_HOST/KEYCLOAK_DB_PASSWORD y volver a correr este script)
  Pre-requisito además del Secret: el esquema MySQL 'keycloak' + su usuario ya
  tienen que existir en esa misma base (ver el comentario de cabecera de
  k8s/shared-secrets/keycloak-secrets.secret.yaml para el SQL exacto), y la
  imagen ghcr.io/digsigna/keycloak:22.0.0-mysql (images/keycloak/Dockerfile)
  ya construida y pusheada."
  exit 1
fi
